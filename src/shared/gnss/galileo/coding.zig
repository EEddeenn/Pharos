const codec = @import("../../codec.zig");
const frame = codec.frame;
const BitWriter = codec.bitwriter.BitWriter;

pub fn append(w: *BitWriter, sync: anytype, comptime n: usize, block: *const frame.Bits(n)) void {
    const interleaver = comptime codec.interleave.block(8, 2 * n / 8);
    w.writeBits(@bitSizeOf(@TypeOf(sync)), sync);
    var encoder: codec.conv.Encoder = .{ .invert_g2 = true };
    var symbols: [2 * n]u1 = undefined;
    for (0..n) |i| {
        const s = encoder.push(block.get(i));
        symbols[2 * i] = s.g1;
        symbols[2 * i + 1] = s.g2;
    }
    var interleaved: [2 * n]u1 = undefined;
    interleaver.apply(u1, &symbols, &interleaved);
    for (interleaved) |s| w.writeBits(1, s);
}

pub fn page(comptime Page: type, sync: anytype, comptime n: usize, content: *const frame.Bits(n)) Page {
    var coded: frame.Bits(n + 24 + 6) = .{};
    var cw = coded.writer();
    for (0..n) |i| cw.writeBits(1, content.get(i));
    cw.writeBits(24, codec.crc24q.ofBits(&content.words, n));
    var out: Page = .{};
    var w = out.writer();
    append(&w, sync, n + 24 + 6, &coded);
    return out;
}
