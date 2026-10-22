const std = @import("std");
const bit_writer = @import("base/binary/bit_writer");

pub fn Bits(comptime n: usize) type {
    return struct {
        words: [word_count]u32 = @splat(0),

        const Self = @This();
        pub const word_count = (n + 31) / 32;
        const byte_count = (n + 7) / 8;

        pub fn get(self: *const Self, i: usize) u1 {
            std.debug.assert(i < n);
            return bit_writer.bitAt(&self.words, i);
        }

        pub fn set(self: *Self, i: usize, bit: u1) void {
            std.debug.assert(i < n);
            const mask = @as(u32, 1) << @intCast(31 - i % 32);
            if (bit == 1) self.words[i / 32] |= mask else self.words[i / 32] &= ~mask;
        }

        pub fn writer(self: *Self) bit_writer.BitWriter {
            return bit_writer.BitWriter.init(&self.words);
        }

        pub fn fromWords(comptime width: u7, comptime count: usize, src: [count]@Int(.unsigned, width)) Self {
            comptime std.debug.assert(width * count == n);
            var out: Self = .{};
            for (src, 0..) |word, k| {
                for (0..width) |j| out.set(k * width + j, @truncate(word >> @intCast(width - 1 - j)));
            }
            return out;
        }

        pub fn toBytes(self: *const Self) [byte_count]u8 {
            var out: [byte_count]u8 = undefined;
            for (&out, 0..) |*b, i| {
                var v: u8 = 0;
                for (0..8) |j| {
                    const bit = i * 8 + j;
                    v = (v << 1) | (if (bit < n) self.get(bit) else 0);
                }
                b.* = v;
            }
            return out;
        }
    };
}
