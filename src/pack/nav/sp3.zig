const std = @import("std");
const diagnostics = @import("shared").core.diagnostics;
const core = @import("shared").core;
const bundle = @import("shared").bundle;
const types = core.types;
const fields = @import("fields.zig");

const tai_minus_gps_s = 19.0;
const absent_clock_us = 999999.999999;
const bad_clock_us = 999999.0;
const civil = core.civil;
const GpsTime = core.time.GpsTime;
const precise = bundle.precise;

const Error = error{ OutOfMemory, MalformedRecord, UnsupportedTimeSystem, UnsupportedVersion, EpochOffGrid, OutOfRange };

pub const TimeSystem = enum {
    gps,
    gal,
    bds,
    tai,
    utc,

    pub fn fromCode(code: []const u8) ?TimeSystem {
        const codes = std.StaticStringMap(TimeSystem).initComptime(.{ .{ "GPS", .gps }, .{ "GAL", .gal }, .{ "BDS", .bds }, .{ "BDT", .bds }, .{ "TAI", .tai }, .{ "UTC", .utc } });
        return codes.get(code);
    }

    pub fn toGps(self: TimeSystem, cal: civil.Utc, leap: civil.Leap) GpsTime {
        return switch (self) {
            .utc => GpsTime.fromUtc(leap, cal),
            .gps, .gal => GpsTime.fromGpsCalendar(cal),
            .bds => GpsTime.fromGpsCalendar(cal).addMs(core.time.bds_offset_ms),
            .tai => GpsTime.fromGpsCalendar(cal).addSeconds(-tai_minus_gps_s),
        };
    }
};

const Sample = @import("shared").bundle.precise.OrbitSample;

pub const File = struct {
    interval_s: f64,
    samples: []const Sample,
};

fn field(line: []const u8, start: usize, width: usize) fields.Error!f64 {
    const token = fields.column(line, start, width) orelse return error.MalformedRecord;
    if (token.len == 0) return 0;
    return fields.float(token) orelse error.MalformedRecord;
}

fn calendar(line: []const u8) fields.Error!civil.Utc {
    const u: civil.Utc = .{
        .year = try fields.intAt(i32, line, 3, 4),
        .month = try fields.intAt(u8, line, 8, 2),
        .day = try fields.intAt(u8, line, 11, 2),
        .hour = try fields.intAt(u8, line, 14, 2),
        .minute = try fields.intAt(u8, line, 17, 2),
        .second = try field(line, 20, 11),
    };
    if (!fields.calendarInRange(u)) return error.MalformedRecord;
    return u;
}

pub fn onGrid(t: GpsTime, t0: GpsTime, interval_s: f64) bool {
    const k = t.secondsSince(t0) / interval_s;
    return @abs(k - @round(k)) <= bundle.precise.grid_tolerance_s / interval_s;
}

pub fn parse(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, scope: diagnostics.Scope) diagnostics.InputError!File {
    var at: usize = 0;
    return parseRaw(arena, source, leap, &at) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedRecord => "an SP3 orbit record or header is malformed",
            error.UnsupportedTimeSystem => "the SP3 time system is unsupported",
            error.UnsupportedVersion => "the SP3 version is unsupported; expected version c or d",
            error.EpochOffGrid => "an SP3 epoch does not lie on the declared sampling grid",
            error.OutOfRange => "an SP3 position or clock value is outside its range",
        };
        return scope.fail(.invalid_format, if (at == 0) null else .{ .line = @intCast(at) }, "{s}", .{message});
    };
}

fn parseRaw(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, at: *usize) Error!File {
    var lines = std.mem.splitScalar(u8, source, '\n');
    errdefer at.* = fields.lineOf(source, lines.index);
    const first = lines.next() orelse return error.MalformedRecord;
    if (first.len < 60 or first[0] != '#') return error.MalformedRecord;
    switch (first[1]) {
        'c', 'd' => {},
        'a', 'b' => return error.UnsupportedVersion,
        else => return error.MalformedRecord,
    }
    const second = lines.next() orelse return error.MalformedRecord;
    if (!std.mem.startsWith(u8, second, "##")) return error.MalformedRecord;
    const interval_s = try field(second, 24, 14);
    if (!(interval_s >= precise.min_interval_s and interval_s <= precise.max_interval_s)) return error.MalformedRecord;
    var time_system: ?TimeSystem = null;
    var line = lines.next();
    while (line) |ln| : (line = lines.next()) {
        if (ln.len == 0 or ln[0] == '*') break;
        if (std.mem.startsWith(u8, ln, "%c") and time_system == null) {
            if (ln.len < 12) return error.MalformedRecord;
            time_system = TimeSystem.fromCode(std.mem.trim(u8, ln[9..12], " ")) orelse return error.UnsupportedTimeSystem;
        }
    }
    const ts = time_system orelse return error.MalformedRecord;
    var samples: std.ArrayList(Sample) = .empty;
    var epoch: ?GpsTime = null;
    var first_epoch: ?GpsTime = null;
    while (line) |ln| : (line = lines.next()) {
        if (ln.len == 0) continue;
        if (ln[0] == '*') {
            const t = ts.toGps(try calendar(ln), leap);
            if (first_epoch) |t0| {
                if (!onGrid(t, t0, interval_s)) return error.EpochOffGrid;
            } else first_epoch = t;
            epoch = t;
            continue;
        }
        if (std.mem.startsWith(u8, ln, "EOF")) break;
        if (ln[0] != 'P') continue;
        const t = epoch orelse return error.MalformedRecord;
        if (ln.len < 4) return error.MalformedRecord;
        const sat = types.SatId.parse(ln[1..4]) orelse continue;
        const x = try field(ln, 4, 14);
        const y = try field(ln, 18, 14);
        const z = try field(ln, 32, 14);
        if (x == 0 and y == 0 and z == 0) continue;
        const pos: [3]f64 = .{ x * 1e3, y * 1e3, z * 1e3 };
        if (!precise.positionInRange(pos)) return error.OutOfRange;
        const clock_raw: f64 = if (ln.len >= 60) try field(ln, 46, 14) else absent_clock_us;
        if (!(clock_raw > -bad_clock_us)) return error.OutOfRange;
        try samples.append(arena, .{
            .sat = sat,
            .t = t,
            .pos = pos,
            .clock_s = if (clock_raw >= bad_clock_us) null else clock_raw * 1e-6,
        });
    }
    return .{ .interval_s = interval_s, .samples = samples.items };
}
