const std = @import("std");
const diagnostics = @import("shared").core.diagnostics;
const core = @import("shared").core;
const fields = @import("fields.zig");
const GpsTime = core.time.GpsTime;
const attitude = core.attitude;
const bundle_antex = @import("shared").bundle.antex;

const Error = error{ OutOfMemory, MalformedRecord, OutOfRange };

const FreqCode = bundle_antex.FreqCode;
const Offset = bundle_antex.Offset;
const Antenna = bundle_antex.Antenna;
const Antex = bundle_antex.Antex;

fn parseFreqCode(code: []const u8) ?FreqCode {
    const sat = core.types.SatId.parse(code) orelse return null;
    return .{ .system = sat.system, .band = sat.prn() };
}

fn intAt(comptime T: type, line: []const u8, start: usize) fields.Error!T {
    if (line.len < start + 6) return error.MalformedRecord;
    return std.fmt.parseInt(T, std.mem.trim(u8, line[start .. start + 6], " "), 10) catch error.MalformedRecord;
}

fn stamp(line: []const u8) fields.Error!GpsTime {
    const cal: core.civil.Utc = .{
        .year = try intAt(i32, line, 0),
        .month = try intAt(u8, line, 6),
        .day = try intAt(u8, line, 12),
        .hour = try intAt(u8, line, 18),
        .minute = try intAt(u8, line, 24),
        .second = try fields.required(line, 30, 13),
    };
    if (!fields.calendarInRange(cal)) return error.MalformedRecord;
    return GpsTime.fromGpsCalendar(cal);
}

fn deg(d: f64) f64 {
    return core.constants.deg2rad(d);
}

const block_iif_yaw_rate_deg_per_s: f64 = 0.11;
const block_iir_yaw_rate_deg_per_s: f64 = 0.2;
const block_ii_yaw_rate_deg_per_s: f64 = 0.1211;
const glonass_yaw_rate_deg_per_s: f64 = 0.25;
const galileo_iov_beta_floor_deg: f64 = 2;
const galileo_iov_along_limit_deg: f64 = 15;
const galileo_foc_beta_limit_deg: f64 = 4.1;
const galileo_foc_colinearity_deg: f64 = 10;
const galileo_foc_period_s: f64 = 5656;
const beidou_2_orbit_normal_beta_deg: f64 = 3;
const beidou_3_beta_floor_deg: f64 = 3;

fn lawOf(kind: []const u8) attitude.Law {
    const rows = [_]struct { prefix: []const u8, law: attitude.Law }{
        .{ .prefix = "BLOCK III", .law = attitude.Law{ .rate_limited = deg(block_iif_yaw_rate_deg_per_s) } },
        .{ .prefix = "BLOCK IIR", .law = attitude.Law{ .rate_limited = deg(block_iir_yaw_rate_deg_per_s) } },
        .{ .prefix = "BLOCK IIF", .law = attitude.Law{ .rate_limited = deg(block_iif_yaw_rate_deg_per_s) } },
        .{ .prefix = "BLOCK II", .law = attitude.Law{ .rate_limited = deg(block_ii_yaw_rate_deg_per_s) } },
        .{ .prefix = "GLONASS-M", .law = attitude.Law{ .shadowed = deg(glonass_yaw_rate_deg_per_s) } },
        .{ .prefix = "GLONASS", .law = attitude.Law{ .rate_limited = deg(glonass_yaw_rate_deg_per_s) } },
        .{ .prefix = "GALILEO-1", .law = attitude.Law{ .auxiliary = .{ .beta_rad = deg(galileo_iov_beta_floor_deg), .along_rad = deg(galileo_iov_along_limit_deg) } } },
        .{ .prefix = "GALILEO", .law = attitude.Law{ .smoothed = .{ .beta_rad = deg(galileo_foc_beta_limit_deg), .colinearity_rad = deg(galileo_foc_colinearity_deg), .period_s = galileo_foc_period_s } } },
        .{ .prefix = "BEIDOU-2G", .law = attitude.Law.orbit_normal },
        .{ .prefix = "BEIDOU-3G", .law = attitude.Law.orbit_normal },
        .{ .prefix = "BEIDOU-2", .law = attitude.Law{ .orbit_normal_below = deg(beidou_2_orbit_normal_beta_deg) } },
        .{ .prefix = "BEIDOU-3M-SECM", .law = attitude.Law{ .beta_floor = deg(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3M-CAST", .law = attitude.Law{ .beta_floor = deg(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3SM-CAST", .law = attitude.Law{ .beta_floor = deg(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3I", .law = attitude.Law{ .beta_floor = deg(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3SI-CAST", .law = attitude.Law{ .beta_floor = deg(beidou_3_beta_floor_deg) } },
    };
    for (rows) |row| if (std.mem.startsWith(u8, kind, row.prefix)) return row.law;
    return .nominal;
}

fn offsetAt(line: []const u8, start: usize) Error!f64 {
    const m = try fields.required(line, start, 10) * 1e-3;
    return if (@abs(m) <= bundle_antex.max_offset_m) m else error.OutOfRange;
}

const Label = enum { start_of_antenna, type_serial, valid_from, valid_until, start_of_frequency, north_east_up, end_of_frequency, end_of_antenna };
const labels = std.StaticStringMap(Label).initComptime(.{
    .{ "START OF ANTENNA", .start_of_antenna },
    .{ "TYPE / SERIAL NO", .type_serial },
    .{ "VALID FROM", .valid_from },
    .{ "VALID UNTIL", .valid_until },
    .{ "START OF FREQUENCY", .start_of_frequency },
    .{ "NORTH / EAST / UP", .north_east_up },
    .{ "END OF FREQUENCY", .end_of_frequency },
    .{ "END OF ANTENNA", .end_of_antenna },
});

pub fn parse(arena: std.mem.Allocator, source: []const u8, scope: diagnostics.Scope) diagnostics.InputError!Antex {
    var at: usize = 0;
    return parseRaw(arena, source, &at) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedRecord => "an ANTEX antenna record is malformed",
            error.OutOfRange => "an ANTEX antenna offset is outside its range",
        };
        return scope.fail(.invalid_format, if (at == 0) null else .{ .line = @intCast(at) }, "{s}", .{message});
    };
}

fn parseRaw(arena: std.mem.Allocator, source: []const u8, at: *usize) Error!Antex {
    var antennas: std.ArrayList(Antenna) = .empty;
    var offsets: std.ArrayList(Offset) = .empty;
    var current: ?Antenna = null;
    var code: ?FreqCode = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    errdefer at.* = fields.lineOf(source, lines.index);
    while (lines.next()) |ln| {
        const label = labels.get(fields.label(ln)) orelse continue;
        if (current == null and label != .start_of_antenna and label != .type_serial) continue;
        switch (label) {
            .start_of_antenna => {
                current = null;
                offsets = .empty;
            },
            .type_serial => {
                const sat = core.types.SatId.parse(std.mem.trim(u8, ln[20..40], " ")) orelse continue;
                const kind = try arena.dupe(u8, std.mem.trim(u8, ln[0..20], " "));
                current = .{
                    .sat = sat,
                    .kind = kind,
                    .law = lawOf(kind),
                    .valid_from = GpsTime.epoch,
                    .valid_until = null,
                    .offsets = &.{},
                };
            },
            .valid_from => current.?.valid_from = try stamp(ln),
            .valid_until => current.?.valid_until = try stamp(ln),
            .start_of_frequency => code = parseFreqCode(std.mem.trim(u8, ln[3..6], " ")),
            .north_east_up => {
                const c = code orelse continue;
                try offsets.append(arena, .{ .code = c, .xyz_m = .{ try offsetAt(ln, 0), try offsetAt(ln, 10), try offsetAt(ln, 20) } });
            },
            .end_of_frequency => code = null,
            .end_of_antenna => {
                current.?.offsets = try arena.dupe(Offset, offsets.items);
                try antennas.append(arena, current.?);
                current = null;
            },
        }
    }
    return .{ .antennas = antennas.items };
}
