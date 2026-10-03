const frame = @import("../../../codec.zig").frame;
const crc24q = @import("../../../codec.zig").crc24q;
const coding = @import("../coding.zig");

pub const symbols_per_page = 500;
const bits_per_part = 120;
const word_bits = 128;
const even_part_word_bits = 112;
pub const Page = frame.Bits(symbols_per_page);
pub const Word = frame.Bits(word_bits);
const Part = frame.Bits(bits_per_part);

const sync: u10 = 0b01_0110_0000;
const crc_even_bits = 114;
const crc_odd_bits = 82;

pub fn encode(word: *const Word, ssp: ?u8) Page {
    const dummy = word.toBytes()[0] >> 2 == 63;
    var even: Part = .{};
    var w = even.writer();
    w.writeBits(2, 0b00);
    for (0..even_part_word_bits) |i| w.writeBits(1, word.get(i));
    var odd: Part = .{};
    w = odd.writer();
    w.writeBits(2, 0b10);
    for (even_part_word_bits..word_bits) |i| w.writeBits(1, word.get(i));
    w.writeBits(40, 0);
    w.writeBits(1, @intFromBool(ssp != null and !dummy));
    w.writeBits(23, 0);
    w.writeBits(24, crc24q.update(crc24q.ofBits(&even.words, crc_even_bits), &odd.words, 0, crc_odd_bits));
    w.writeBits(8, if (dummy) 0 else ssp orelse 0);
    var page: Page = .{};
    var pw = page.writer();
    coding.append(&pw, sync, bits_per_part, &even);
    coding.append(&pw, sync, bits_per_part, &odd);
    return page;
}
