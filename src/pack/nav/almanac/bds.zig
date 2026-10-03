const std = @import("std");
const time = @import("shared").core.time;
const fields = @import("../fields.zig");
const records = @import("shared").gnss.records;
const almanac = @import("../almanac.zig");

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

pub fn matches(line: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    var count: usize = 0;
    while (tokens.next()) |token| : (count += 1) if (fields.float(token) == null) return false;
    return count >= 12;
}

pub fn read(arena: std.mem.Allocator, source: []const u8, at: *usize) almanac.Error!almanac.Result {
    var list: std.ArrayList(Almanac) = .empty;
    var skipped: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    errdefer at.* = fields.lineOf(source, lines.index);
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        var values: [12][]const u8 = undefined;
        for (&values) |*v| v.* = tokens.next() orelse return error.MalformedRecord;
        const svid = fields.int(i64, values[0]) orelse return error.MalformedRecord;
        const toa = fields.int(i64, values[2]) orelse return error.MalformedRecord;
        const week = fields.int(i64, values[11]) orelse return error.MalformedRecord;
        var f: [9]f64 = undefined;
        for (&f, 0..) |*v, i| v.* = fields.float(values[if (i == 0) 1 else i + 2]) orelse return error.MalformedRecord;
        const sat = almanac.satOf(.bds, svid) orelse {
            skipped += 1;
            continue;
        };
        if (toa < 0 or toa >= time.s_per_week or week < 0 or week > time.max_week) {
            skipped += 1;
            continue;
        }
        try list.append(arena, .{ .kepler = .{
            .sat = sat,
            .toa = GpsTime.fromScaleWeekMs(.bds, week, toa * 1000, 0),
            .health = 0,
            .iod = 0,
            .ecc = f[0],
            .i0 = f[1],
            .omega_dot = f[2],
            .sqrt_a = f[3],
            .omega0 = f[4],
            .w = f[5],
            .m0 = f[6],
            .af0 = f[7],
            .af1 = f[8],
        } });
    }
    return .{ .almanacs = list.items, .skipped = skipped };
}
