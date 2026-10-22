const time = @import("domain/time/gps");
const ldpc = @import("base/binary/ldpc");
const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const almanac = @import("domain/messages/bds/fields/almanac");
const content = @import("domain/messages/bds/bcnav2/fields");
const blobs = @import("domain/messages/bds/data/manifest");
const Set = @import("domain/messages/bds/bcnav/set").Set;
const crc24q = @import("base/binary/crc").crc24q;
const Error = field.Error;
const Type = content.Type;
const messages_per_week = 201_600;
const content_bits = 264;
const Message = frame.Bits(288);
const preamble: u24 = 0xE24DE8;
const message_ldpc = ldpc.Gf64Systematic(48).init(blobs.b2a_gen.bytes);
const codeword_bits = 576;

pub const frame_ms = 3000;
pub const bits_per_frame = 600;
pub const Frame = frame.Bits(bits_per_frame);
const order = [20]Type{
    .ephemeris_1, .ephemeris_2, .clock_iono,            .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_reduced_almanac, .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_eop,             .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_bgto,            .midi_almanac,
    .ephemeris_1, .ephemeris_2, .clock_utc,             .midi_almanac,
};

const Slot = struct { kind: Type, sow: u18, wn: u13, prns: [3]u7, bgto: u2 = 0 };

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const m = messageBits(set, prn, slot(index)) catch unreachable;
    return encodeFrame(&m);
}

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

fn messageBits(set: *const Set, prn: u8, requested: Slot) Error!Message {
    const data = set;
    var s = requested;
    if (s.kind == .clock_eop and data.system.eop == null) s.kind = .clock_iono;
    if (s.kind == .clock_utc and data.system.utc == null) {
        s.kind = .clock_reduced_almanac;
        s.prns = reducedPrns(s.sow / 20);
    }
    var alm: [3]almanac.Packet = undefined;
    for (&alm, s.prns) |*packet, number| packet.* = data.almanacs.packet(number);
    var out: Message = .{};
    var w = out.writer();
    try content.encode(data.sv[prn - 1].?, .{
        .reference = data.almanacs.reference,
        .alm = alm,
        .bdgim = data.system.bdgim,
        .utc = data.system.utc,
        .eop = data.system.eop,
        .bgto = data.system.bgto(s.bgto),
    }, .{ .prn = @intCast(prn), .kind = s.kind, .sow = s.sow, .wn = s.wn }, &w);
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}

fn reducedPrns(cycle: i64) [3]u7 {
    var prns: [3]u7 = @splat(0);
    for (0..3) |k| prns[k] = @intCast(@mod(4 * cycle + @as(i64, @intCast(k)), 63) + 1);
    return prns;
}

fn encodeFrame(m: *const Message) Frame {
    var bits: [codeword_bits]u1 = undefined;
    message_ldpc.codeword(m, &bits);
    var out: Frame = .{};
    for (0..24) |i| out.set(i, @truncate(preamble >> @intCast(23 - i)));
    for (bits, 0..) |b, i| out.set(24 + i, b);
    return out;
}
