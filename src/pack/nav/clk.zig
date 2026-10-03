const std = @import("std");
const diagnostics = @import("shared").core.diagnostics;
const core = @import("shared").core;
const civil = core.civil;
const fields = @import("fields.zig");
const sp3 = @import("sp3.zig");
const precise = @import("shared").bundle.precise;

const Error = error{ OutOfMemory, MalformedRecord, UnsupportedTimeSystem, MissingEndOfHeader, OutOfRange };

const Sample = precise.ClockRecord;

const Label = enum { version, time_system, end_of_header };
const labels = std.StaticStringMap(Label).initComptime(.{ .{ "RINEX VERSION / TYPE", .version }, .{ "TIME SYSTEM ID", .time_system }, .{ "END OF HEADER", .end_of_header } });

pub fn parse(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, scope: diagnostics.Scope) diagnostics.InputError![]const Sample {
    var at: usize = 0;
    return parseRaw(arena, source, leap, &at) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedRecord => "a RINEX clock record or header is malformed",
            error.UnsupportedTimeSystem => "the RINEX clock time system is unsupported",
            error.MissingEndOfHeader => "the RINEX clock header has no END OF HEADER line",
            error.OutOfRange => "a RINEX clock bias is outside its range",
        };
        return scope.fail(.invalid_format, if (at == 0) null else .{ .line = @intCast(at) }, "{s}", .{message});
    };
}

fn parseRaw(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, at: *usize) Error![]const Sample {
    var lines = std.mem.splitScalar(u8, source, '\n');
    errdefer at.* = fields.lineOf(source, lines.index);
    var version: f64 = 0;
    var time_system: ?sp3.TimeSystem = null;
    var line = lines.next();
    const ended = while (line) |ln| : (line = lines.next()) {
        switch (labels.get(fields.label(ln)) orelse continue) {
            .version => {
                version = fields.float(std.mem.trim(u8, ln[0..9], " ")) orelse return error.MalformedRecord;
                if (ln[20] != 'C') return error.MalformedRecord;
            },
            .time_system => time_system = sp3.TimeSystem.fromCode(std.mem.trim(u8, ln[3..6], " ")) orelse return error.UnsupportedTimeSystem,
            .end_of_header => {
                line = lines.next();
                break true;
            },
        }
    } else false;
    if (version == 0) return error.MalformedRecord;
    if (!ended) return error.MissingEndOfHeader;
    const ts = time_system orelse .gps;
    var samples: std.ArrayList(Sample) = .empty;
    while (line) |ln| : (line = lines.next()) {
        if (!std.mem.startsWith(u8, ln, "AS")) continue;
        var it = std.mem.tokenizeAny(u8, ln[2..], " \r");
        const name = it.next() orelse return error.MalformedRecord;
        const cal: core.civil.Utc = .{
            .year = fields.int(i32, it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord,
            .month = fields.int(u8, it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord,
            .day = fields.int(u8, it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord,
            .hour = fields.int(u8, it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord,
            .minute = fields.int(u8, it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord,
            .second = fields.float(it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord,
        };
        const count = it.next() orelse return error.MalformedRecord;
        if ((std.fmt.parseInt(u8, count, 10) catch return error.MalformedRecord) < 1) return error.MalformedRecord;
        const bias = fields.float(it.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord;
        const sat = core.types.SatId.parse(name) orelse continue;
        if (!fields.calendarInRange(cal)) return error.MalformedRecord;
        if (!(@abs(bias) <= precise.max_clock_s)) return error.OutOfRange;
        try samples.append(arena, .{ .sat = sat, .t = ts.toGps(cal, leap), .bias_s = bias });
    }
    return samples.items;
}
