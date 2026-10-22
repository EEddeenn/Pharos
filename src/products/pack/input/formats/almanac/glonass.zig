const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const fields = @import("products/pack/input/navigation/fields");
const records = @import("domain/navigation/records");
const almanac = @import("products/pack/input/formats/almanac/read");
const orbit = @import("domain/navigation/orbit/glonass");
const angles = @import("base/math/angles");
const Rejections = @import("products/pack/input/rejections").Rejections;

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

const agl_century = 2000;

pub fn matches(line: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    _ = tokens.next() orelse return false;
    return isDate(tokens.next() orelse return false);
}

pub fn read(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, issues: *Rejections) std.mem.Allocator.Error![]Almanac {
    var list: std.ArrayList(Almanac) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const value = readLine(line, leap) catch |err| {
            try issues.line(arena, .glo, "AGL almanac", line, number, if (err == error.OutOfRange) .implausible else .malformed, "");
            continue;
        };
        if (value) |record| try list.append(arena, record) else issues.ignore();
    }
    return list.items;
}

fn isDate(token: []const u8) bool {
    if (token.len != 8 or token[2] != '.' or token[5] != '.') return false;
    for ([_]usize{ 0, 1, 3, 4, 6, 7 }) |i| if (!std.ascii.isDigit(token[i])) return false;
    return true;
}

fn readLine(line: []const u8, leap: civil.Leap) error{ MalformedRecord, OutOfRange }!?Almanac {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    var values: [11][]const u8 = undefined;
    for (&values) |*value| value.* = tokens.next() orelse return error.MalformedRecord;
    const slot = fields.int(i64, values[0]) orelse return error.MalformedRecord;
    if (!isDate(values[1])) return error.MalformedRecord;
    const day = fields.int(u8, values[1][0..2]) orelse return error.MalformedRecord;
    const month = fields.int(u8, values[1][3..5]) orelse return error.MalformedRecord;
    const year = fields.int(i32, values[1][6..8]) orelse return error.MalformedRecord;
    if (!civil.isDate(agl_century + year, month, day) or slot <= 0) return error.OutOfRange;
    var numbers: [8]f64 = undefined;
    for (&numbers, 0..) |*value, i| value.* = fields.float(values[if (i < 7) i + 2 else 10]) orelse return error.MalformedRecord;
    const frequency = fields.int(i32, values[9]) orelse return error.MalformedRecord;
    const freq = gnss_types.FreqId.fromInt(frequency) catch return error.OutOfRange;
    const sat = almanac.satOf(.glo, slot) orelse return null;
    const date = GpsTime.fromUtc(leap, .{ .year = agl_century + year, .month = month, .day = day, .hour = 0, .minute = 0, .second = 0 }).toGlonass(leap);
    return .{ .glonass = .{
        .sat = sat,
        .freq = freq,
        .health = true,
        .mn = null,
        .n4 = @intCast(date.n4),
        .na = date.nt,
        .t_lambda_s = numbers[0],
        .delta_t = numbers[1] - orbit.mean_draconic_period_s,
        .ecc = numbers[2],
        .delta_i = angles.deg2rad(numbers[3] - orbit.mean_inclination_deg),
        .lambda = angles.deg2rad(numbers[4]),
        .w = angles.deg2rad(numbers[5]),
        .tau_n = numbers[6],
        .delta_t_dot = numbers[7],
    } };
}
