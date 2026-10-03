const std = @import("std");
const types = @import("../../core.zig").types;
const time = @import("../../core.zig").time;

const Signal = types.Signal;
const Signals = std.EnumSet(Signal);

const Block = enum {
    none,
    iir,
    iir_m,
    iif,
    iii,

    fn signals(block: Block) Signals {
        return switch (block) {
            .none => .empty,
            .iir => .initMany(&.{.l1ca}),
            .iir_m => .initMany(&.{ .l1ca, .l2c }),
            .iif => .initMany(&.{ .l1ca, .l2c, .l5 }),
            .iii => .initMany(&.{ .l1ca, .l2c, .l5, .l1c }),
        };
    }

    fn configuration(block: Block) u3 {
        return switch (block) {
            .none => 0b000,
            .iir => 0b001,
            .iir_m => 0b010,
            .iif => 0b011,
            .iii => 0b100,
        };
    }
};

pub const start = utc(2025, 1, 1, 0, 0);

fn first(prn: u8) Block {
    return switch (prn) {
        1, 4, 11, 14, 18, 23, 28 => .iii,
        3, 6, 8, 9, 10, 24, 25, 26, 27, 30, 32 => .iif,
        5, 7, 12, 15, 17, 29, 31 => .iir_m,
        2, 13, 16, 19, 20, 21, 22 => .iir,
        else => .none,
    };
}

const Change = struct { prn: u8, at: time.GpsTime, block: Block };

const changes = [_]Change{
    .{ .prn = 21, .at = utc(2025, 1, 27, 22, 15), .block = .none },
    .{ .prn = 21, .at = utc(2025, 5, 30, 0, 0), .block = .iii },
    .{ .prn = 20, .at = utc(2025, 8, 4, 22, 0), .block = .none },
    .{ .prn = 20, .at = utc(2025, 9, 30, 0, 0), .block = .iir },
    .{ .prn = 20, .at = utc(2026, 1, 8, 22, 0), .block = .none },
    .{ .prn = 20, .at = utc(2026, 1, 28, 0, 0), .block = .iii },
    .{ .prn = 13, .at = utc(2026, 4, 24, 22, 0), .block = .iii },
};

fn utc(year: i32, month: u8, day: u8, hour: u8, minute: u8) time.GpsTime {
    return .fromUtc(.table, .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = 0 });
}

fn blockAt(prn: u8, t: time.GpsTime) Block {
    var block = first(prn);
    for (changes) |c| {
        if (c.prn == prn and !t.lessThan(c.at)) block = c.block;
    }
    return block;
}

pub fn signalsAt(prn: u8, t: time.GpsTime) Signals {
    return blockAt(prn, t).signals();
}

pub fn configurationAt(t: time.GpsTime) [63]u3 {
    var out: [63]u3 = @splat(0);
    for (&out, 1..) |*code, prn| code.* = blockAt(@intCast(prn), t).configuration();
    return out;
}
