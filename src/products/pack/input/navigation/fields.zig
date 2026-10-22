const std = @import("std");
const civil = @import("domain/time/civil");
const rejections = @import("products/pack/input/rejections");

pub const Error = error{MalformedRecord};

pub const IntegerError = error{ NonIntegral, OutOfRange };

pub fn column(line: []const u8, start: usize, width: usize) ?[]const u8 {
    if (line.len <= start) return null;
    return std.mem.trim(u8, line[start..@min(line.len, start + width)], " \r\n");
}

pub fn label(line: []const u8) []const u8 {
    return column(line, 60, line.len) orelse "";
}

pub fn lineOf(source: []const u8, next: ?usize) usize {
    const end = if (next) |i| i -| 1 else source.len;
    return std.mem.countScalar(u8, source[0..end], '\n') + 1;
}

pub fn float(text: []const u8) ?f64 {
    var buffer: [32]u8 = undefined;
    if (text.len > buffer.len) return null;
    for (text, 0..) |ch, i| buffer[i] = if (ch == 'D' or ch == 'd') 'E' else ch;
    const v = std.fmt.parseFloat(f64, buffer[0..text.len]) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

pub fn int(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch null;
}

pub fn numberToken(rejected: *rejections.Rejection, name: [:0]const u8, token: ?[]const u8) rejections.RecordError!f64 {
    const text = token orelse return rejected.fail(name, null, .blank);
    if (text.len == 0) return rejected.fail(name, text, .blank);
    return float(text) orelse rejected.fail(name, text, .malformed);
}

pub fn integerToken(comptime T: type, rejected: *rejections.Rejection, name: [:0]const u8, token: ?[]const u8) rejections.RecordError!T {
    const text = token orelse return rejected.fail(name, null, .blank);
    if (text.len == 0) return rejected.fail(name, text, .blank);
    return int(T, text) orelse {
        const value = float(text) orelse return rejected.fail(name, text, .malformed);
        _ = integerValue(T, value) catch |err| return rejected.fail(name, text, switch (err) {
            error.NonIntegral => .non_integral,
            error.OutOfRange => .implausible,
        });
        return rejected.fail(name, text, .malformed);
    };
}

pub fn floatAt(line: []const u8, start: usize, width: usize) Error!?f64 {
    const token = column(line, start, width) orelse return null;
    if (token.len == 0) return null;
    return float(token) orelse error.MalformedRecord;
}

pub fn required(line: []const u8, start: usize, width: usize) Error!f64 {
    return try floatAt(line, start, width) orelse error.MalformedRecord;
}

pub fn intAt(comptime T: type, line: []const u8, start: usize, width: usize) Error!T {
    const token = column(line, start, width) orelse return error.MalformedRecord;
    return std.fmt.parseInt(T, token, 10) catch error.MalformedRecord;
}

pub fn calendarInRange(u: civil.Utc) bool {
    return civil.isDate(u.year, u.month, u.day) and
        u.hour <= 23 and u.minute <= 59 and
        u.second >= 0 and u.second < 61;
}

pub fn integerValue(comptime T: type, value: f64) IntegerError!T {
    const whole = @trunc(value);
    if (value != whole) return error.NonIntegral;
    const minimum: f64 = @floatFromInt(std.math.minInt(T));
    const maximum: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(whole >= minimum and whole < maximum + 1.0)) return error.OutOfRange;
    return @intFromFloat(whole);
}
