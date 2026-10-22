const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const bcnav_content = @import("domain/messages/bds/bcnav/content");
const fields = @import("domain/messages/bds/bcnav1/fields");
const ephemeris = @import("domain/messages/bds/fields/ephemeris");
const almanac = @import("domain/messages/bds/fields/almanac");
const iono = @import("domain/messages/bds/fields/ionosphere");
const time_parameters = @import("domain/messages/bds/fields/time");
const time = @import("domain/time/gps");
const bch = @import("base/binary/bch");
const ldpc = @import("base/binary/ldpc");
const interleave = @import("base/binary/interleave");
const blobs = @import("domain/messages/bds/data/manifest");
const Set = @import("domain/messages/bds/bcnav/set").Set;
const crc24q = @import("base/binary/crc").crc24q;
const Sv = bcnav_content.Candidate;
const Error = field.Error;
const sf2_data_bits = 576;
const sf3_data_bits = 240;
const Sf2 = frame.Bits(600);
const Sf3 = frame.Bits(264);
const frames_per_week = 33_600;
const frames_per_hour = 200;
const frames_per_page_cycle = 100;
const sf2_codeword_bits = 1200;
const sf3_codeword_bits = 528;
const interleaved_bits = sf2_codeword_bits + sf3_codeword_bits;
const subframe2_ldpc = ldpc.Gf64Systematic(100).init(blobs.b1c_gen2.bytes);
const subframe3_ldpc = ldpc.Gf64Systematic(44).init(blobs.b1c_gen3.bytes);
const interleaver: interleave.Permutation(interleaved_bits) = blk: {
    @setEvalBranchQuota(20_000);
    var p: interleave.Permutation(interleaved_bits) = undefined;
    for (0..48) |j| for (0..36) |col| {
        const src = if (col < 33) switch (col % 3) {
            0 => (col / 3) * 96 + j,
            1 => (col / 3) * 96 + 48 + j,
            else => sf2_codeword_bits + (col / 3) * 48 + j,
        } else (22 + (col - 33)) * 48 + j;
        p.map[j * 36 + col] = src;
    };
    break :blk p;
};

const Page = union(enum) { p0, p1, p2: [4]u7, p3: u2, p4: u7 };

pub const frame_ms = 18_000;
pub const bits_per_frame = 1800;
pub const Frame = frame.Bits(bits_per_frame);

const Slot = struct { wn: u13, how: u8, soh: u8, page: Page };

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const f = slot(index);
    const sf2_bits = subframe2Bits(set, prn, .{ .wn = f.wn, .how = f.how }) catch unreachable;
    const sf3_bits = subframe3Bits(set, prn, f.page) catch unreachable;
    var bits: [interleaved_bits]u1 = undefined;
    subframe2_ldpc.codeword(&sf2_bits, bits[0..sf2_codeword_bits]);
    subframe3_ldpc.codeword(&sf3_bits, bits[sf2_codeword_bits..interleaved_bits]);
    var interleaved: [interleaved_bits]u1 = undefined;
    interleaver.apply(u1, &bits, &interleaved);
    var out: Frame = .{};
    const s1 = subframe1(@intCast(prn), f.soh);
    for (0..72) |i| out.set(i, @truncate(s1 >> @intCast(71 - i)));
    for (interleaved, 0..) |b, i| out.set(72 + i, b);
    return out;
}

fn subframe2Bits(set: *const Set, prn: u8, ctx: fields.Ctx2) Error!Sf2 {
    var out: Sf2 = .{};
    var w = out.writer();
    const sv = set.sv[prn - 1].?;
    try field.encode(fields.Ctx2, &fields.sf2_header, &ctx, .{}, &w);
    field.writeDecoded(ephemeris.Source, &(ephemeris.iodc ++ ephemeris.eph1 ++ ephemeris.eph2 ++ ephemeris.clock), sv.ephemeris.codes, &w);
    field.writeDecoded(Sv, &fields.sf2_tail, sv.codes.bcnav1, &w);
    w.writeBits(24, crc24q.ofBits(&out.words, sf2_data_bits));
    return out;
}

fn subframe3Bits(set: *const Set, prn: u8, requested: Page) Error!Sf3 {
    var out: Sf3 = .{};
    var w = out.writer();
    const data = set;
    const sv = data.sv[prn - 1].?;
    var page = requested;
    if (page == .p3 and data.system.eop == null) page = .p1;
    if (page == .p1 and data.system.utc == null) page = .p0;
    switch (page) {
        .p0 => field.writeDecoded(Sv, &fields.page0, sv.codes.bcnav1, &w),
        .p1 => {
            field.writeDecoded(Sv, &fields.page1_header, sv.codes.bcnav1, &w);
            field.writeDecoded(iono.Coefficients, &iono.bdgim, data.system.bdgim, &w);
            field.writeDecoded(time_parameters.Utc, &time_parameters.utc, data.system.utc.?, &w);
            try field.encode(field.NoSource, &fields.page1_tail, &field.no_source, .{}, &w);
        },
        .p2 => |prns| {
            field.writeDecoded(Sv, &fields.page2_header, sv.codes.bcnav1, &w);
            try field.encode(almanac_epoch.Reference, &almanac_epoch.rows, &data.almanacs.reference, .{}, &w);
            for (prns) |p| try field.encode(almanac.Packet, &almanac.reduced, &data.almanacs.packet(p), .{}, &w);
            try field.encode(field.NoSource, &fields.page2_tail, &field.no_source, .{}, &w);
        },
        .p3 => |target| {
            field.writeDecoded(Sv, &fields.page3_header, sv.codes.bcnav1, &w);
            field.writeDecoded(time_parameters.Eop, &time_parameters.eop, data.system.eop.?, &w);
            field.writeDecoded(time_parameters.Bgto, &time_parameters.bgto, data.system.bgto(target), &w);
            try field.encode(field.NoSource, &fields.page3_tail, &field.no_source, .{}, &w);
        },
        .p4 => |p| {
            field.writeDecoded(Sv, &fields.page4_header, sv.codes.bcnav1, &w);
            try field.encode(almanac.Packet, &almanac.midi, &data.almanacs.packet(p), .{}, &w);
            try field.encode(field.NoSource, &fields.page4_tail, &field.no_source, .{}, &w);
        },
    }
    w.writeBits(24, crc24q.ofBits(&out.words, sf3_data_bits));
    return out;
}

fn subframe1(prn: u6, soh: u8) u72 {
    return (@as(u72, bch.bch21.codeword(prn)) << 51) | bch.bch51.codeword(soh);
}

fn slot(index: i64) Slot {
    const in_week = @mod(index, frames_per_week);
    const soh: u8 = @intCast(@mod(in_week, frames_per_hour));
    const i: u32 = if (soh >= frames_per_page_cycle) soh - frames_per_page_cycle else soh;
    const page: Page = blk: {
        if (i % 10 == 0) break :blk .p1;
        if (i % 10 == 5) {
            break :blk .{ .p3 = @intCast(@mod(@divFloor(index, 10), 3)) };
        }
        if (i % 5 == 1 and i < 80) {
            const base = (i / 5) * 4;
            break :blk .{ .p2 = .{
                @intCast(base + 1),
                @intCast(base + 2),
                @intCast(base + 3),
                if (base + 4 <= 63) @intCast(base + 4) else 0,
            } };
        }
        if (i == 99) break :blk .p0;

        const almanac_index = if (i < 80)
            (i / 5) * 3 + i % 5 - 2
        else
            (i / 5) * 4 + i % 5 - 17;
        break :blk .{ .p4 = @intCast(1 + almanac_index) };
    };
    const wn: u13 = @intCast(@mod(time.weekOfIndex(index, frames_per_week, .bds), time.week_modulus_13));
    const how: u8 = @intCast(@divFloor(in_week, frames_per_hour));

    return .{ .wn = wn, .how = how, .soh = soh, .page = page };
}
