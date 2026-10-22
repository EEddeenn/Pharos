const std = @import("std");
const time = @import("domain/time/gps");
const fields = @import("products/pack/input/navigation/fields");
const records = @import("domain/navigation/records");
const almanac = @import("products/pack/input/formats/almanac/read");
const Rejections = @import("products/pack/input/rejections").Rejections;

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

pub fn matches(line: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    var count: usize = 0;
    while (tokens.next()) |token| : (count += 1) if (fields.float(token) == null) return false;
    return count >= 12;
}

pub fn read(arena: std.mem.Allocator, source: []const u8, issues: *Rejections) std.mem.Allocator.Error![]Almanac {
    var list: std.ArrayList(Almanac) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const value = readLine(line) catch |err| {
            try issues.line(arena, .bds, "almanac", line, number, if (err == error.OutOfRange) .implausible else .malformed, "");
            continue;
        };
        if (value) |record| try list.append(arena, record) else issues.ignore();
    }
    return list.items;
}

fn readLine(line: []const u8) error{ MalformedRecord, OutOfRange }!?Almanac {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    var values: [12][]const u8 = undefined;
    for (&values) |*value| value.* = tokens.next() orelse return error.MalformedRecord;
    const svid = fields.int(i64, values[0]) orelse return error.MalformedRecord;
    const toa = fields.int(i64, values[2]) orelse return error.MalformedRecord;
    const week = fields.int(i64, values[11]) orelse return error.MalformedRecord;
    var numbers: [9]f64 = undefined;
    for (&numbers, 0..) |*value, i| value.* = fields.float(values[if (i == 0) 1 else i + 2]) orelse return error.MalformedRecord;
    if (svid <= 0 or toa < 0 or toa >= time.s_per_week or week < 0 or week > time.max_week) return error.OutOfRange;
    const sat = almanac.satOf(.bds, svid) orelse return null;
    return .{ .kepler = .{
        .sat = sat,
        .toa = GpsTime.fromScaleWeekMs(.bds, week, toa * 1000, 0),
        .health = 0,
        .iod = 0,
        .ecc = numbers[0],
        .i0 = numbers[1],
        .omega_dot = numbers[2],
        .sqrt_a = numbers[3],
        .omega0 = numbers[4],
        .w = numbers[5],
        .m0 = numbers[6],
        .af0 = numbers[7],
        .af1 = numbers[8],
    } };
}
