const std = @import("std");
const types = @import("../../core.zig").types;
const time = @import("../../core.zig").time;
const records = @import("records.zig");

const Signal = types.Signal;
const Signals = std.EnumSet(Signal);

const bds2: Signals = .initMany(&.{ .b1i, .b2i, .b3i });
const bds3: Signals = .initMany(&.{ .b1i, .b3i, .b1c, .b2a, .b2b });
const bds3_geo: Signals = .initMany(&.{ .b1i, .b3i, .b2b });

fn before(prn: u8) Signals {
    if (prn <= 18) return bds2;
    return if (records.isGeo(prn)) bds3_geo else bds3;
}

fn after(prn: u8) Signals {
    return switch (prn) {
        1...4 => bds3_geo,
        6...8, 11...14, 19...39, 41, 42 => bds3,
        9, 10 => .initMany(&.{ .b1i, .b3i }),
        40 => .initMany(&.{ .b3i, .b2a, .b2b }),
        else => .empty,
    };
}

const Move = struct { from: u8, to: u8, day: u8, hour: u8 };

const moves = [_]Move{
    .{ .from = 38, .to = 6, .day = 10, .hour = 12 },
    .{ .from = 39, .to = 7, .day = 17, .hour = 0 },
    .{ .from = 40, .to = 8, .day = 17, .hour = 6 },
    .{ .from = 60, .to = 2, .day = 17, .hour = 13 },
    .{ .from = 13, .to = 9, .day = 18, .hour = 3 },
    .{ .from = 61, .to = 3, .day = 18, .hour = 7 },
    .{ .from = 16, .to = 10, .day = 18, .hour = 11 },
    .{ .from = 45, .to = 39, .day = 18, .hour = 22 },
    .{ .from = 50, .to = 14, .day = 19, .hour = 4 },
    .{ .from = 49, .to = 13, .day = 19, .hour = 8 },
    .{ .from = 47, .to = 11, .day = 19, .hour = 23 },
    .{ .from = 44, .to = 31, .day = 20, .hour = 4 },
    .{ .from = 43, .to = 38, .day = 20, .hour = 8 },
    .{ .from = 62, .to = 1, .day = 20, .hour = 12 },
    .{ .from = 46, .to = 40, .day = 20, .hour = 23 },
    .{ .from = 48, .to = 12, .day = 21, .hour = 4 },
    .{ .from = 59, .to = 4, .day = 21, .hour = 8 },
};

const reallocation_year = 2026;
const reallocation_month = 4;

fn change(prn: u8) time.GpsTime {
    var at: struct { day: u8, hour: u8 } = .{ .day = 21, .hour = 12 };
    for (moves) |move| {
        if (move.from != prn and move.to != prn) continue;
        const earlier = move.day < at.day or (move.day == at.day and move.hour < at.hour);
        if (earlier) at = .{ .day = move.day, .hour = move.hour };
    }
    return time.GpsTime.fromUtc(.table, .{ .year = reallocation_year, .month = reallocation_month, .day = at.day, .hour = at.hour, .minute = 0, .second = 0 });
}

pub fn signalsAt(prn: u8, t: time.GpsTime) Signals {
    return if (t.lessThan(change(prn))) before(prn) else after(prn);
}

pub fn carriesPppB2b(prn: u8) bool {
    return records.isGeo(prn);
}
