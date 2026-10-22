const std = @import("std");
const diagnostics = @import("base/diagnostics");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const time = @import("domain/time/gps");
const catalog = @import("domain/navigation/antenna/catalog");
const fields = @import("products/pack/input/navigation/fields");
const rejections = @import("products/pack/input/rejections");

const GpsTime = time.GpsTime;
const FreqCode = catalog.FreqCode;
const Offset = catalog.Offset;
const Antenna = catalog.Antenna;
const Rejections = rejections.Rejections;
const Rejection = rejections.Rejection;
const RecordError = rejections.RecordError;
const Error = error{ OutOfMemory, MalformedRecord, MissingEndOfHeader, IncompleteAntenna };
const Label = enum { start_of_antenna, type_serial, valid_from, valid_until, start_of_frequency, north_east_up, end_of_frequency, start_of_rms, end_of_rms, end_of_antenna };
const labels = std.StaticStringMap(Label).initComptime(.{
    .{ "START OF ANTENNA", .start_of_antenna },
    .{ "TYPE / SERIAL NO", .type_serial },
    .{ "VALID FROM", .valid_from },
    .{ "VALID UNTIL", .valid_until },
    .{ "START OF FREQUENCY", .start_of_frequency },
    .{ "NORTH / EAST / UP", .north_east_up },
    .{ "END OF FREQUENCY", .end_of_frequency },
    .{ "START OF FREQ RMS", .start_of_rms },
    .{ "END OF FREQ RMS", .end_of_rms },
    .{ "END OF ANTENNA", .end_of_antenna },
});

pub fn parse(arena: std.mem.Allocator, source: []const u8, scope: diagnostics.Scope) diagnostics.InputError![]const Antenna {
    var at: usize = 0;
    var issues: Rejections = .{};
    const result = parseRaw(arena, source, &at, &issues) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedRecord => "an ANTEX header or antenna boundary is malformed",
            error.MissingEndOfHeader => "the ANTEX header has no END OF HEADER line",
            error.IncompleteAntenna => "the last ANTEX antenna block has no END OF ANTENNA line",
        };
        try issues.report(scope);
        return scope.fail(.invalid_format, if (at == 0) null else .{ .text = .{ .line = std.math.lossyCast(u32, at) } }, "{s}", .{message});
    };
    try issues.report(scope);
    return result;
}

fn parseRaw(arena: std.mem.Allocator, source: []const u8, at: *usize, issues: *Rejections) Error![]const Antenna {
    var lines = std.mem.splitScalar(u8, source, '\n');
    at.* = 1;
    const first = lines.next() orelse return error.MalformedRecord;
    if (!std.mem.eql(u8, fields.label(first), "ANTEX VERSION / SYST")) return error.MalformedRecord;
    const version = try fields.required(first, 0, 8);
    if (!(version > 0)) return error.MalformedRecord;
    const ended = while (lines.next()) |line| {
        at.* += 1;
        const label = fields.label(line);
        if (std.mem.eql(u8, label, "END OF HEADER")) break true;
        if (std.mem.eql(u8, label, "START OF ANTENNA")) return error.MissingEndOfHeader;
    } else false;
    if (!ended) return error.MissingEndOfHeader;

    var antennas: std.ArrayList(Antenna) = .empty;
    var block: ?struct { start: usize, line: usize } = null;
    while (lines.index) |start| {
        const line = lines.next() orelse break;
        at.* += 1;
        const label = labels.get(fields.label(line)) orelse continue;
        switch (label) {
            .start_of_antenna => {
                if (block) |previous| {
                    const body = source[previous.start..start];
                    var rejected = issue(body, previous.line, "END OF ANTENNA");
                    rejected.reason = .blank;
                    try issues.add(arena, rejected);
                }
                block = .{ .start = lines.index orelse source.len, .line = at.* + 1 };
            },
            .end_of_antenna => {
                const current = block orelse return error.MalformedRecord;
                const body = source[current.start..start];
                var rejected = issue(body, current.line, "TYPE / SERIAL NO");
                const antenna = readAntenna(arena, body, current.line, &rejected, issues) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.RejectedRecord => {
                        if (rejected.original_token) |token| {
                            const location = std.zig.findLineColumn(body, @intFromPtr(token.ptr) - @intFromPtr(body.ptr));
                            rejected.location = .{ .text = .{ .line = std.math.lossyCast(u32, current.line + location.line), .column = std.math.lossyCast(u32, location.column + 1) } };
                        }
                        try issues.add(arena, rejected);
                        block = null;
                        continue;
                    },
                };
                if (antenna) |value| try antennas.append(arena, value) else issues.ignore();
                block = null;
            },
            else => if (block == null) return error.MalformedRecord,
        }
    }
    if (block) |unfinished| {
        at.* = unfinished.line - 1;
        return error.IncompleteAntenna;
    }
    return antennas.items;
}

fn issue(body: []const u8, line_number: usize, field_name: [:0]const u8) Rejection {
    const end = std.mem.findScalar(u8, body, '\n') orelse body.len;
    return .{ .system = null, .named = .{ .label = body[0..@min(end, 80)] }, .message = "ANTEX antenna", .field = field_name, .reason = .blank, .location = .{ .text = .{ .line = std.math.lossyCast(u32, line_number) } } };
}

fn stamp(line: []const u8, rejected: *Rejection) RecordError!GpsTime {
    const cal: civil.Utc = .{
        .year = try fields.integerToken(i32, rejected, "year", fields.column(line, 0, 6)),
        .month = try fields.integerToken(u8, rejected, "month", fields.column(line, 6, 6)),
        .day = try fields.integerToken(u8, rejected, "day", fields.column(line, 12, 6)),
        .hour = try fields.integerToken(u8, rejected, "hour", fields.column(line, 18, 6)),
        .minute = try fields.integerToken(u8, rejected, "minute", fields.column(line, 24, 6)),
        .second = try fields.numberToken(rejected, "second", fields.column(line, 30, 13)),
    };
    if (!fields.calendarInRange(cal)) return rejected.fail("validity epoch", fields.column(line, 0, 43), .implausible);
    return GpsTime.fromGpsCalendar(cal);
}

fn frequencyCode(line: []const u8, rejected: *Rejection) RecordError!?FreqCode {
    const code = fields.column(line, 3, 3) orelse return rejected.fail("frequency", null, .blank);
    if (code.len != 3 or !std.ascii.isUpper(code[0])) return rejected.fail("frequency", code, .malformed);
    const system = gnss_types.System.fromRinexLetter(code[0]) orelse return null;
    const band = try fields.integerToken(u8, rejected, "frequency", code[1..]);
    if (band == 0) return rejected.fail("frequency", code, .implausible);
    const id = gnss_types.SatId.fromPrn(system, band) catch return null;
    return .{ .system = system, .band = id.prn() };
}

fn offsetAt(line: []const u8, start: usize, name: [:0]const u8, rejected: *Rejection) RecordError!f64 {
    const token = fields.column(line, start, 10);
    const value = try fields.numberToken(rejected, name, token) * 1e-3;
    return if (@abs(value) <= catalog.max_offset_m) value else rejected.fail(name, token, .implausible);
}

fn readAntenna(arena: std.mem.Allocator, body: []const u8, first_line: usize, rejected: *Rejection, issues: *Rejections) (std.mem.Allocator.Error || RecordError)!?Antenna {
    var antenna: ?Antenna = null;
    var offsets: std.ArrayList(Offset) = .empty;
    defer offsets.deinit(arena);
    var frequency: union(enum) { none, ignored, rms, known: struct { code: FreqCode, offset: ?Offset = null } } = .none;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var line_number = first_line;
    while (lines.next()) |line| : (line_number += 1) {
        const label = labels.get(fields.label(line)) orelse continue;
        rejected.location = .{ .text = .{ .line = std.math.lossyCast(u32, line_number) } };
        if (antenna == null and label != .type_serial) return rejected.fail("TYPE / SERIAL NO", null, .blank);
        switch (label) {
            .type_serial => {
                if (antenna != null) return rejected.fail("TYPE / SERIAL NO", fields.column(line, 0, 40), .malformed);
                const name = fields.column(line, 20, 20) orelse return rejected.fail("satellite", null, .blank);
                // Receiver antennas and other constellations are outside this satellite catalog.
                if (name.len != 3) return null;
                const system = gnss_types.System.fromRinexLetter(name[0]) orelse return null;
                rejected.system = system;
                const prn = try fields.integerToken(u32, rejected, "satellite", name[1..]);
                if (prn == 0) return rejected.fail("satellite", name, .implausible);
                const sat = gnss_types.SatId.fromPrn(system, prn) catch return null;
                antenna = .{ .sat = sat, .kind = std.mem.trim(u8, line[0..20], " "), .valid_from = GpsTime.epoch, .valid_until = null, .offsets = &.{} };
            },
            .valid_from => antenna.?.valid_from = try stamp(line, rejected),
            .valid_until => antenna.?.valid_until = try stamp(line, rejected),
            .start_of_frequency => {
                if (frequency != .none) return rejected.fail("END OF FREQUENCY", null, .blank);
                if (try frequencyCode(line, rejected)) |code| {
                    if (code.system != antenna.?.sat.system) return rejected.fail("frequency", fields.column(line, 3, 3), .mismatch);
                    frequency = .{ .known = .{ .code = code } };
                } else {
                    frequency = .ignored;
                    issues.ignore();
                }
            },
            .north_east_up => switch (frequency) {
                .none => return rejected.fail("START OF FREQUENCY", null, .blank),
                .ignored, .rms => {},
                .known => |*value| {
                    if (value.offset != null) return rejected.fail("NORTH / EAST / UP", fields.column(line, 0, 30), .malformed);
                    value.offset = .{ .code = value.code, .xyz_m = .{ try offsetAt(line, 0, "north_mm", rejected), try offsetAt(line, 10, "east_mm", rejected), try offsetAt(line, 20, "up_mm", rejected) } };
                },
            },
            .end_of_frequency => {
                switch (frequency) {
                    .none => return rejected.fail("START OF FREQUENCY", null, .blank),
                    .rms => return rejected.fail("END OF FREQ RMS", null, .blank),
                    .ignored => {},
                    .known => |value| try offsets.append(arena, value.offset orelse return rejected.fail("NORTH / EAST / UP", null, .blank)),
                }
                frequency = .none;
            },
            .start_of_rms => {
                if (frequency != .none) return rejected.fail("END OF FREQUENCY", null, .blank);
                frequency = .rms;
            },
            .end_of_rms => {
                if (frequency != .rms) return rejected.fail("START OF FREQ RMS", null, .blank);
                frequency = .none;
            },
            .start_of_antenna, .end_of_antenna => return rejected.fail("antenna boundary", fields.label(line), .malformed),
        }
    }
    if (frequency != .none) return rejected.fail("END OF FREQUENCY", null, .blank);
    var result = antenna orelse return rejected.fail("TYPE / SERIAL NO", null, .blank);
    result.kind = try arena.dupe(u8, result.kind);
    errdefer arena.free(result.kind);
    result.offsets = try offsets.toOwnedSlice(arena);
    return result;
}
