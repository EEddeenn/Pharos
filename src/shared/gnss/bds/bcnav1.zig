const time = @import("../../core.zig").time;
const bch = @import("../../codec.zig").bch;
const ldpc = @import("../../codec.zig").ldpc;
const interleave = @import("../../codec.zig").interleave;
const frame = @import("../../codec.zig").frame;
const blobs = @import("blobs/manifest.zig");
const content = @import("bcnav1/content.zig");

pub const frame_ms = 18_000;
const frames_per_week = 33_600;
pub const bits_per_frame = 1800;
const frames_per_hour = 200;
const frames_per_page_cycle = 100;
const sf2_codeword_bits = 1200;
const sf3_codeword_bits = 528;
const interleaved_bits = sf2_codeword_bits + sf3_codeword_bits;
pub const Frame = frame.Bits(bits_per_frame);
pub const Set = content.Set;

fn subframe1(prn: u6, soh: u8) u72 {
    return (@as(u72, bch.bch21.codeword(prn)) << 51) | bch.bch51.codeword(soh);
}

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

const Slot = struct { wn: u13, how: u8, soh: u8, page: content.Page };

fn slot(index: i64) Slot {
    const in_week = @mod(index, frames_per_week);
    const soh: u8 = @intCast(@mod(in_week, frames_per_hour));
    const i: u32 = if (soh >= frames_per_page_cycle) soh - frames_per_page_cycle else soh;
    const page: content.Page = blk: {
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

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const f = slot(index);
    const sf2_bits = content.subframe2Bits(set, prn, .{ .wn = f.wn, .how = f.how }) catch unreachable;
    const sf3_bits = content.subframe3Bits(set, prn, f.page) catch unreachable;
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
