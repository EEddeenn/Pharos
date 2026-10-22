const std = @import("std");
const bit_writer = @import("base/binary/bit_writer");

pub const crc24q = Crc(24, 0x864CFB);
pub const crc32q = Crc(32, 0x814141AB);

fn Crc(comptime width: u16, comptime polynomial: @Int(.unsigned, width)) type {
    return struct {
        pub const Value = @Int(.unsigned, width);

        pub fn update(crc: Value, words: []const u32, from: usize, to: usize) Value {
            std.debug.assert(from <= to and to <= words.len * 32);
            var c = crc;
            for (from..to) |i| {
                const feedback = @as(u1, @truncate(c >> (width - 1))) ^ bit_writer.bitAt(words, i);
                c = if (feedback == 1) (c << 1) ^ polynomial else c << 1;
            }
            return c;
        }

        pub fn ofBits(words: []const u32, nbits: usize) Value {
            return update(0, words, 0, nbits);
        }
    };
}
