const std = @import("std");
const civil = @import("shared").core.civil;

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

pub const Error = error{MalformedRecord};

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
    return u.year >= civil.first_year and u.year <= civil.last_year and
        u.month >= 1 and u.month <= 12 and
        u.day >= 1 and u.day <= 31 and
        u.hour <= 23 and u.minute <= 59 and
        u.second >= 0 and u.second < 61;
}

pub fn intFromFloat(comptime T: type, v: f64) ?T {
    if (!std.math.isFinite(v)) return null;
    const t = @trunc(v);
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (t < lo or t >= hi + 1.0) return null;
    return @intFromFloat(t);
}

pub fn intField(comptime T: type, v: f64) Error!T {
    return intFromFloat(T, v) orelse error.MalformedRecord;
}
