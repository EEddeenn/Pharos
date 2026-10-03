const bch = @import("../../codec.zig").bch;
const ldpc = @import("../../codec.zig").ldpc;
const interleave = @import("../../codec.zig").interleave;
const frame = @import("../../codec.zig").frame;
const blobs = @import("blobs/manifest.zig");
const content = @import("cnav2/content.zig");
pub const publications = @import("cnav2/publications.zig");

pub const frame_ms = content.frame_ms;
const frames_per_week = 33_600;
const frames_per_itow = 400;
const toi_default = 511;
const sf2_bits = 600;
const sf3_bits = 274;
const sf2_codeword_bits = 1200;
const sf3_codeword_bits = 548;
const encoded_bits = 1748;
pub const bits_per_frame = 1800;
pub const Frame = frame.Bits(bits_per_frame);
pub const Set = content.Set;

fn subframe1(toi: u9) u52 {
    const msb: u1 = @truncate(toi >> 8);
    const code: u51 = bch.bch51.codeword(@truncate(toi));
    const mixed: u51 = if (msb == 1) ~code else code;
    return (@as(u52, msb) << 51) | mixed;
}

const subframe2_ldpc = ldpc.Gf2Systematic(sf2_bits, 19).init(blobs.l1c_gen2.bytes);
const subframe3_ldpc = ldpc.Gf2Systematic(sf3_bits, 9).init(blobs.l1c_gen3.bytes);
const interleaver = interleave.block(46, 38);

const Slot = struct { itow: u8, toi: u9 };

fn slot(index: i64) Slot {
    const page = @mod(index, frames_per_week);
    return .{
        .itow = @intCast(@divFloor(page, frames_per_itow)),
        .toi = @intCast(@mod(page + 1, frames_per_itow)),
    };
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const sv = if (set.data.sv[prn - 1]) |*sv| sv else return null;
    const f = slot(index);
    const isf = set.isfAt(sv, .{ .ms = index * frame_ms });
    const sf2 = content.subframe2Bits(sv, f.itow, isf) catch unreachable;
    const page = content.pageAt(set, prn, index);
    const sf3 = content.subframe3Bits(set, prn, page) catch unreachable;

    var symbols: [encoded_bits]u1 = undefined;
    for (0..sf2_bits) |i| symbols[i] = sf2.get(i);
    var parity2: [sf2_codeword_bits - sf2_bits]u1 = undefined;
    subframe2_ldpc.parity(&sf2.words, &parity2);
    @memcpy(symbols[sf2_bits..sf2_codeword_bits], &parity2);

    for (0..sf3_bits) |i| symbols[sf2_codeword_bits + i] = sf3.get(i);
    var parity3: [sf3_codeword_bits - sf3_bits]u1 = undefined;
    subframe3_ldpc.parity(&sf3.words, &parity3);
    @memcpy(symbols[sf2_codeword_bits + sf3_bits .. encoded_bits], &parity3);

    var interleaved: [encoded_bits]u1 = undefined;
    interleaver.apply(u1, &symbols, &interleaved);

    var out: Frame = .{};
    const s1 = subframe1(if (content.isDefault(set, page, isf)) toi_default else f.toi);
    for (0..52) |i| out.set(i, @truncate(s1 >> @intCast(51 - i)));
    for (interleaved, 0..) |b, i| out.set(52 + i, b);
    return out;
}
