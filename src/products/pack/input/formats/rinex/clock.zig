const std = @import("std");
const diagnostics = @import("base/diagnostics");
const civil = @import("domain/time/civil");
const gnss_types = @import("domain/gnss_types");
const precise = @import("domain/navigation/precise/product");
const fields = @import("products/pack/input/navigation/fields");
const sp3 = @import("products/pack/input/formats/sp3");
const rejections = @import("products/pack/input/rejections");

const Sample = precise.ClockRecord;
const Rejections = rejections.Rejections;
const Rejection = rejections.Rejection;
const RecordError = rejections.RecordError;
const Error = error{ OutOfMemory, MalformedRecord, UnsupportedTimeSystem, MissingEndOfHeader };
const Label = enum { version, time_system, end_of_header };
const labels = std.StaticStringMap(Label).initComptime(.{ .{ "RINEX VERSION / TYPE", .version }, .{ "TIME SYSTEM ID", .time_system }, .{ "END OF HEADER", .end_of_header } });
const value_names = [_][:0]const u8{ "bias_s", "bias sigma", "clock rate", "clock rate sigma", "clock acceleration", "clock acceleration sigma" };

pub fn parse(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, scope: diagnostics.Scope) diagnostics.InputError![]const Sample {
    var at: usize = 0;
    var issues: Rejections = .{};
    const result = parseRaw(arena, source, leap, &at, &issues) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedRecord => "a RINEX clock header or record boundary is malformed",
            error.UnsupportedTimeSystem => "the RINEX clock time system is unsupported",
            error.MissingEndOfHeader => "the RINEX clock header has no END OF HEADER line",
        };
        try issues.report(scope);
        return scope.fail(.invalid_format, if (at == 0) null else .{ .text = .{ .line = std.math.lossyCast(u32, at) } }, "{s}", .{message});
    };
    try issues.report(scope);
    return result;
}

fn parseRaw(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, at: *usize, issues: *Rejections) Error![]const Sample {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var version: f64 = 0;
    var time_system: ?sp3.TimeSystem = null;
    const ended = while (lines.next()) |line| {
        at.* += 1;
        switch (labels.get(fields.label(line)) orelse continue) {
            .version => {
                version = try fields.required(line, 0, 9);
                if (!(version > 0) or line[20] != 'C') return error.MalformedRecord;
            },
            .time_system => time_system = sp3.TimeSystem.fromCode(fields.column(line, 3, 3) orelse return error.MalformedRecord) orelse return error.UnsupportedTimeSystem,
            .end_of_header => break true,
        }
    } else false;
    if (!ended) return error.MissingEndOfHeader;
    if (version == 0 or (version >= 3.04 and time_system == null)) return error.MalformedRecord;
    const ts = time_system orelse .gps;
    var samples: std.ArrayList(Sample) = .empty;
    while (lines.index) |start| {
        const line = lines.next() orelse break;
        at.* += 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (!recordStart(line)) return error.MalformedRecord;
        const first_line = at.*;
        // Continuation lines belong only to this record; a following typed line is never consumed as its values.
        while (lines.peek()) |next| {
            if (next.len != 0 and !std.ascii.isWhitespace(next[0])) break;
            _ = lines.next();
            at.* += 1;
        }
        const record = source[start .. lines.index orelse source.len];
        if (!std.mem.eql(u8, line[0..2], "AS")) {
            issues.ignore();
            continue;
        }
        var rejected: Rejection = .{
            .system = null,
            .named = .{ .label = line[0..@min(line.len, 80)] },
            .message = "RINEX clock",
            .location = .{ .text = .{ .line = std.math.lossyCast(u32, first_line) } },
        };
        const sample = readRecord(record, ts, leap, &rejected) catch {
            if (rejected.original_token) |token| {
                const location = std.zig.findLineColumn(record, @intFromPtr(token.ptr) - @intFromPtr(record.ptr));
                rejected.location = .{ .text = .{ .line = std.math.lossyCast(u32, first_line + location.line), .column = std.math.lossyCast(u32, location.column + 1) } };
            }
            try issues.add(arena, rejected);
            continue;
        };
        if (sample) |value| try samples.append(arena, value) else issues.ignore();
    }
    return samples.items;
}

fn recordStart(line: []const u8) bool {
    return line.len >= 2 and std.ascii.isUpper(line[0]) and std.ascii.isUpper(line[1]) and
        (line.len == 2 or line[2] == ' ' or line[2] == '\t');
}

fn readRecord(record: []const u8, ts: sp3.TimeSystem, leap: civil.Leap, rejected: *Rejection) RecordError!?Sample {
    var tokens = std.mem.tokenizeAny(u8, record[2..], " \t\r\n");
    const name = tokens.next() orelse return rejected.fail("satellite", null, .blank);
    if (name.len != 3 or !std.ascii.isUpper(name[0])) return rejected.fail("satellite", name, .malformed);
    const system = gnss_types.System.fromRinexLetter(name[0]) orelse return null;
    rejected.system = system;
    const prn = try fields.integerToken(u32, rejected, "satellite", name[1..]);
    if (prn == 0) return rejected.fail("satellite", name, .implausible);
    const sat = gnss_types.SatId.fromPrn(system, prn) catch return null;
    const epoch_start = tokens.peek();
    const cal: civil.Utc = .{
        .year = try fields.integerToken(i32, rejected, "year", tokens.next()),
        .month = try fields.integerToken(u8, rejected, "month", tokens.next()),
        .day = try fields.integerToken(u8, rejected, "day", tokens.next()),
        .hour = try fields.integerToken(u8, rejected, "hour", tokens.next()),
        .minute = try fields.integerToken(u8, rejected, "minute", tokens.next()),
        .second = try fields.numberToken(rejected, "second", tokens.next()),
    };
    if (!fields.calendarInRange(cal)) return rejected.fail("epoch", if (epoch_start) |token| record[@intFromPtr(token.ptr) - @intFromPtr(record.ptr) .. tokens.index + 2] else null, .implausible);
    const count_token = tokens.next();
    const count = try fields.integerToken(u8, rejected, "value count", count_token);
    if (count < 1 or count > value_names.len) return rejected.fail("value count", count_token, .implausible);
    const bias_token = tokens.next();
    const bias = try fields.numberToken(rejected, "bias_s", bias_token);
    if (!(@abs(bias) <= precise.max_clock_s)) return rejected.fail("bias_s", bias_token, .implausible);
    for (value_names[1..count]) |field_name| {
        const token = tokens.next() orelse return rejected.fail(field_name, null, .blank);
        if (!decimal(token)) return rejected.fail(field_name, token, .malformed);
    }
    if (tokens.next()) |extra| return rejected.fail("clock data", extra, .malformed);
    return .{ .sat = sat, .t = ts.toGps(cal, leap), .bias_s = bias };
}

// These declared metadata fields are unused; only their decimal token syntax is relevant.
fn decimal(token: []const u8) bool {
    var at: usize = 0;
    if (at < token.len and (token[at] == '+' or token[at] == '-')) at += 1;
    var digits: usize = 0;
    while (at < token.len and std.ascii.isDigit(token[at])) : (at += 1) digits += 1;
    if (at < token.len and token[at] == '.') {
        at += 1;
        while (at < token.len and std.ascii.isDigit(token[at])) : (at += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (at < token.len and (token[at] == 'e' or token[at] == 'E' or token[at] == 'd' or token[at] == 'D')) {
        at += 1;
        if (at < token.len and (token[at] == '+' or token[at] == '-')) at += 1;
        const first = at;
        while (at < token.len and std.ascii.isDigit(token[at])) at += 1;
        if (at == first) return false;
    }
    return at == token.len;
}
