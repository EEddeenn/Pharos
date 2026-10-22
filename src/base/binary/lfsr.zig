const std = @import("std");

pub fn Lfsr(comptime bits: u8) type {
    return struct {
        state: State,
        taps: State,

        const Self = @This();
        pub const State = @Int(.unsigned, bits);

        pub fn step(self: *Self) u1 {
            const out: u1 = @truncate(self.state >> (bits - 1));
            const fb: u1 = @truncate(@popCount(self.state & self.taps));
            self.state = (self.state << 1) | fb;
            return out;
        }

        pub fn sum(self: Self, mask: State) u1 {
            return @truncate(@popCount(self.state & mask));
        }
    };
}

pub fn gold(comptime bits: u8, taps1: Lfsr(bits).State, taps2: Lfsr(bits).State, start: Lfsr(bits).State, restart: ?usize, out: []u8) void {
    const ones = std.math.maxInt(Lfsr(bits).State);
    var r1: Lfsr(bits) = .{ .state = ones, .taps = taps1 };
    var r2: Lfsr(bits) = .{ .state = start, .taps = taps2 };
    const at = restart orelse out.len;
    for (out, 0..) |*chip, i| {
        if (i == at) r1.state = ones;
        chip.* = r1.step() ^ r2.step();
    }
}

pub fn Modular(comptime bits: u8) type {
    return struct {
        state: State,
        taps: State,

        const Self = @This();
        pub const State = @Int(.unsigned, bits);

        pub fn step(self: *Self) u1 {
            const out: u1 = @truncate(self.state);
            self.state >>= 1;
            if (out == 1) self.state ^= self.taps;
            return out;
        }
    };
}
