const std = @import("std");
const bitwriter = @import("bitwriter.zig");

pub fn Bits(comptime n: usize) type {
    return struct {
        const Self = @This();
        pub const word_count = (n + 31) / 32;
        const byte_count = (n + 7) / 8;
        words: [word_count]u32 = @splat(0),

        pub fn get(self: *const Self, i: usize) u1 {
            std.debug.assert(i < n);
            return bitwriter.bitAt(&self.words, i);
        }

        pub fn set(self: *Self, i: usize, bit: u1) void {
            std.debug.assert(i < n);
            const mask = @as(u32, 1) << @intCast(31 - i % 32);
            if (bit == 1) self.words[i / 32] |= mask else self.words[i / 32] &= ~mask;
        }

        pub fn writer(self: *Self) bitwriter.BitWriter {
            return bitwriter.BitWriter.init(&self.words);
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

pub fn Supplier(comptime T: type) type {
    return struct {
        ptr: *const anyopaque,
        frameFn: *const fn (*const anyopaque, prn: u8, index: i64) ?T,

        pub fn frame(self: @This(), prn: u8, index: i64) ?T {
            return self.frameFn(self.ptr, prn, index);
        }

        pub fn of(comptime S: type, supplier: *const S) @This() {
            return .{ .ptr = supplier, .frameFn = struct {
                fn call(p: *const anyopaque, prn: u8, index: i64) ?T {
                    const s: *const S = @ptrCast(@alignCast(p));
                    return s.frame(prn, index);
                }
            }.call };
        }
    };
}

pub fn Source(comptime n: usize) type {
    return Supplier(Bits(n));
}
