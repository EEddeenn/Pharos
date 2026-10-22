const std = @import("std");
const civil = @import("domain/time/civil");
const fields = @import("products/pack/input/navigation/fields");

pub const Error = error{ OutOfMemory, MalformedRecord, NotNavigation, UnsupportedVersion, MissingEndOfHeader };

pub const Lines = std.mem.SplitIterator(u8, .scalar);

pub const Epoch = struct { utc: civil.Utc, head: [3]?f64 };

pub fn field(line: []const u8, start: usize) fields.Error!f64 {
    return try fields.floatAt(line, start, 19) orelse 0;
}

pub fn optionalInt(line: []const u8, start: usize, width: usize) fields.Error!?i64 {
    const token = fields.column(line, start, width) orelse return null;
    if (token.len == 0) return null;
    return fields.int(i64, token) orelse error.MalformedRecord;
}

pub fn calendar(line: []const u8) fields.Error!civil.Utc {
    if (line.len < 23) return error.MalformedRecord;
    const utc: civil.Utc = .{
        .year = try fields.intAt(i32, line, 4, 4),
        .month = try fields.intAt(u8, line, 9, 2),
        .day = try fields.intAt(u8, line, 12, 2),
        .hour = try fields.intAt(u8, line, 15, 2),
        .minute = try fields.intAt(u8, line, 18, 2),
        .second = @floatFromInt(try fields.intAt(u8, line, 21, 2)),
    };
    if (!fields.calendarInRange(utc)) return error.MalformedRecord;
    return utc;
}

pub fn epochLine(line: []const u8) fields.Error!Epoch {
    return .{ .utc = try calendar(line), .head = .{ try fields.floatAt(line, 23, 19), try fields.floatAt(line, 42, 19), try fields.floatAt(line, 61, 19) } };
}

pub fn optionalBodyLine(lines: *Lines) fields.Error![4]?f64 {
    return bodyColumns(continuation(lines) orelse return error.MalformedRecord);
}

/// The next line where it continues the record: a RINEX 3 record starts with its satellite, and each further line with spaces.
pub fn continuation(lines: *Lines) ?[]const u8 {
    const next = lines.peek() orelse return null;
    if (next.len == 0 or next[0] != ' ') return null;
    return lines.next();
}

pub fn nextInBlock(lines: *Lines) ?[]const u8 {
    const next = lines.peek() orelse return null;
    if (next.len > 0 and next[0] == '>') return null;
    return lines.next();
}

pub fn bodyColumns(line: []const u8) fields.Error![4]?f64 {
    return .{ try fields.floatAt(line, 4, 19), try fields.floatAt(line, 23, 19), try fields.floatAt(line, 42, 19), try fields.floatAt(line, 61, 19) };
}
