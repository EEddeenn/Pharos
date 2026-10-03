const ldpc = @import("../../../codec.zig").ldpc;
const frame = @import("../../../codec.zig").frame;
const blobs = @import("../blobs/manifest.zig");

const codeword_bits = 972;

pub const bits_per_frame = 1000;
pub const content_bits = 462;
pub const Frame = frame.Bits(bits_per_frame);
pub const Message = frame.Bits(486);
const preamble: u16 = 0xEB90;

const message_ldpc = ldpc.Gf64Systematic(81).init(blobs.b2b_gen.bytes);

pub const FrameSource = frame.Source(bits_per_frame);

pub fn encodeFrame(m: *const Message, prn: u8) Frame {
    var bits: [codeword_bits]u1 = undefined;
    message_ldpc.codeword(m, &bits);
    var out: Frame = .{};
    for (0..16) |i| out.set(i, @truncate(preamble >> @intCast(15 - i)));
    for (0..6) |i| out.set(16 + i, @truncate(prn >> @intCast(5 - i)));
    for (bits, 0..) |b, i| out.set(28 + i, b);
    return out;
}

pub fn encodePppFrame(m: *const Message, prn: u8, available: bool) Frame {
    var out = encodeFrame(m, prn);
    out.set(22, @intFromBool(!available));
    return out;
}
