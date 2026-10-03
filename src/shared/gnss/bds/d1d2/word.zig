const frame = @import("../../../codec.zig").frame;
const bch = @import("../../../codec.zig").bch;

pub const frame_bits = 300;
pub const info_bits = 198;
pub const Frame = frame.Bits(frame_bits);
pub const Info = frame.Bits(info_bits);
const preamble: u11 = 0b11100010010;

const bch15 = bch.Systematic(11, 15, &.{ 0, 1, 2, 3, 5, 7, 8 });

fn shuffle2x15(first: u15, second: u15) u30 {
    var out: u30 = 0;
    for (0..15) |j| {
        const k: u4 = @intCast(14 - j);
        out = (out << 2) | ((first >> k) & 1) << 1 | ((second >> k) & 1);
    }
    return out;
}

fn message(info: *const Info, k: usize) u11 {
    var out: u11 = 0;
    for (11 * k..11 * k + 11) |i| out = (out << 1) | info.get(i);
    return out;
}

pub fn encodeSubframe(fra_id: u3, sow: u20, info: *const Info) Frame {
    var words: [10]u30 = undefined;
    words[0] = @as(u30, preamble) << 19 | bch15.codeword((@as(u11, fra_id) << 8) | @as(u11, @intCast(sow >> 12)));
    for (words[1..], 0..) |*word, k| word.* = shuffle2x15(bch15.codeword(message(info, 2 * k)), bch15.codeword(message(info, 2 * k + 1)));
    return .fromWords(30, 10, words);
}
