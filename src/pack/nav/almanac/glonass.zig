const std = @import("std");
const types = @import("shared").core.types;
const time = @import("shared").core.time;
const civil = @import("shared").core.civil;
const fields = @import("../fields.zig");
const records = @import("shared").gnss.records;
const almanac = @import("../almanac.zig");
const constants = @import("shared").core.constants;
const orbit = @import("shared").gnss.glonass.orbit;

const agl_century = 2000;

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

fn isDate(token: []const u8) bool {
    if (token.len != 8 or token[2] != '.' or token[5] != '.') return false;
    for ([_]usize{ 0, 1, 3, 4, 6, 7 }) |i| if (!std.ascii.isDigit(token[i])) return false;
    return true;
}

pub fn matches(line: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    _ = tokens.next() orelse return false;
    return isDate(tokens.next() orelse return false);
}

pub fn read(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, at: *usize) almanac.Error!almanac.Result {
    var list: std.ArrayList(Almanac) = .empty;
    var skipped: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    errdefer at.* = fields.lineOf(source, lines.index);
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        var values: [11][]const u8 = undefined;
        for (&values) |*v| v.* = tokens.next() orelse return error.MalformedRecord;
        const slot = fields.int(i64, values[0]) orelse return error.MalformedRecord;
        if (!isDate(values[1])) return error.MalformedRecord;
        const day = fields.int(u8, values[1][0..2]) orelse return error.MalformedRecord;
        const month = fields.int(u8, values[1][3..5]) orelse return error.MalformedRecord;
        const year = fields.int(i32, values[1][6..8]) orelse return error.MalformedRecord;
        var f: [8]f64 = undefined;
        for (&f, 0..) |*v, i| v.* = fields.float(values[if (i < 7) i + 2 else 10]) orelse return error.MalformedRecord;
        const freq = fields.int(i64, values[9]) orelse return error.MalformedRecord;
        const sat = almanac.satOf(.glo, slot) orelse {
            skipped += 1;
            continue;
        };
        const freq_id = (if (std.math.cast(i32, freq)) |k| types.FreqId.fromInt(k) else error.FreqIdOutOfRange) catch {
            skipped += 1;
            continue;
        };
        if (month < 1 or month > 12 or day < 1 or day > 31) {
            skipped += 1;
            continue;
        }
        const date = GpsTime.fromUtc(leap, .{ .year = agl_century + year, .month = month, .day = day, .hour = 0, .minute = 0, .second = 0 }).toGlonass(leap);
        try list.append(arena, .{ .glonass = .{
            .sat = sat,
            .freq = freq_id,
            .health = true,
            .mn = null,
            .n4 = @intCast(date.n4),
            .na = date.nt,
            .t_lambda_s = f[0],
            .delta_t = f[1] - orbit.mean_draconic_period_s,
            .ecc = f[2],
            .delta_i = constants.deg2rad(f[3] - orbit.mean_inclination_deg),
            .lambda = constants.deg2rad(f[4]),
            .w = constants.deg2rad(f[5]),
            .tau_n = f[6],
            .delta_t_dot = f[7],
        } });
    }
    return .{ .almanacs = list.items, .skipped = skipped };
}
