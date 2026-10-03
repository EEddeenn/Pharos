const time = @import("../../core.zig").time;
const ldpc = @import("../../codec.zig").ldpc;
const field = @import("../../codec.zig").field;
const frame = @import("../../codec.zig").frame;
const crc24q = @import("../../codec.zig").crc24q;
const almanac = @import("almanac_fields.zig");
const bcnav = @import("bcnav.zig");
const content = @import("bcnav2/content.zig");
const blobs = @import("blobs/manifest.zig");

pub const frame_ms = 3000;
const messages_per_week = 201_600;
pub const bits_per_frame = 600;
const content_bits = 264;
pub const Frame = frame.Bits(bits_per_frame);
const Message = frame.Bits(288);
const Error = field.Error;
const preamble: u24 = 0xE24DE8;

pub const Set = struct {
    data: bcnav.Data,

    pub const Inputs = bcnav.Inputs;

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.data.build(.bcnav2, in);
        try set.validate();
    }

    fn validate(set: *const Set) Error!void {
        var first: ?u8 = null;
        for (&set.data.sv, 1..) |*entry, number| {
            if (entry.* == null) continue;
            const prn: u8 = @intCast(number);
            if (first == null) first = prn;
            _ = try messageBits(set, prn, .{ .kind = .clock_iono, .sow = 0, .wn = 0, .prns = @splat(0) });
        }
        const prn = first orelse return;
        for ([_]Type{ .clock_eop, .clock_utc }) |kind| _ = try messageBits(set, prn, .{ .kind = kind, .sow = 0, .wn = 0, .prns = @splat(0) });
        for (0..3) |target| _ = try messageBits(set, prn, .{ .kind = .clock_bgto, .sow = 0, .wn = 0, .prns = @splat(0), .bgto = @intCast(target) });
    }

    pub fn hasRecord(set: *const Set, prn: u8) bool {
        return set.data.hasRecord(prn);
    }
};

const message_ldpc = ldpc.Gf64Systematic(48).init(blobs.b2a_gen.bytes);

const Type = content.Type;

const order = [20]Type{
    .ephemeris_1, .ephemeris_2, .clock_iono,            .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_reduced_almanac, .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_eop,             .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_bgto,            .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_utc,             .midi_almanac,
};

const Slot = struct { kind: Type, sow: u18, wn: u13, prns: [3]u7, bgto: u2 = 0 };

fn slot(index: i64) Slot {
    const in_week = @mod(index, messages_per_week);
    const kind = order[@intCast(@mod(index, 20))];
    var prns = [_]u7{ 0, 0, 0 };
    const r = @divFloor(index, 20);
    switch (kind) {
        .clock_reduced_almanac => prns = reducedPrns(r),
        .clock_bgto => prns[0] = @intCast(@mod(4 * r + 3, 63) + 1),
        .midi_almanac => prns[0] = @intCast(@mod(@divFloor(index, 4), 63) + 1),
        else => {},
    }
    const wn: u13 = @intCast(@mod(time.weekOfIndex(index, messages_per_week, .bds), time.week_modulus_13));
    const bgto: u2 = @intCast(@mod(r, 3));

    return .{
        .kind = kind,
        .sow = @intCast(in_week),
        .wn = wn,
        .prns = prns,
        .bgto = bgto,
    };
}

fn reducedPrns(cycle: i64) [3]u7 {
    var prns: [3]u7 = @splat(0);
    for (0..3) |k| prns[k] = @intCast(@mod(4 * cycle + @as(i64, @intCast(k)), 63) + 1);
    return prns;
}

fn messageBits(set: *const Set, prn: u8, requested: Slot) Error!Message {
    const data = &set.data;
    var s = requested;
    if (s.kind == .clock_eop and data.eop == null) s.kind = .clock_iono;
    if (s.kind == .clock_utc and data.utc == null) {
        s.kind = .clock_reduced_almanac;
        s.prns = reducedPrns(s.sow / 20);
    }
    var alm: [3]almanac.Packet = undefined;
    for (&alm, s.prns) |*packet, number| packet.* = data.packet(number);
    var out: Message = .{};
    var w = out.writer();
    try content.encode(&data.sv[prn - 1].?, .{
        .reference = data.almanac_reference,
        .alm = alm,
        .bdgim = data.bdgim,
        .utc = data.utc,
        .eop = data.eop,
        .bgto = data.bgto(s.bgto),
    }, .{ .prn = @intCast(prn), .kind = s.kind, .sow = s.sow, .wn = s.wn }, &w);
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const m = messageBits(set, prn, slot(index)) catch unreachable;
    return encodeFrame(&m);
}

const codeword_bits = 576;

fn encodeFrame(m: *const Message) Frame {
    var bits: [codeword_bits]u1 = undefined;
    message_ldpc.codeword(m, &bits);
    var out: Frame = .{};
    for (0..24) |i| out.set(i, @truncate(preamble >> @intCast(23 - i)));
    for (bits, 0..) |b, i| out.set(24 + i, b);
    return out;
}
