const std = @import("std");
const diagnostics = @import("base/diagnostics");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const precise = @import("domain/navigation/precise/product");
const fields = @import("products/pack/input/navigation/fields");
const rejections = @import("products/pack/input/rejections");

const GpsTime = time.GpsTime;
const Sample = precise.OrbitSample;
const Rejections = rejections.Rejections;
const Rejection = rejections.Rejection;
const RecordError = rejections.RecordError;
const Error = error{ OutOfMemory, MalformedRecord, UnsupportedTimeSystem, UnsupportedVersion, EpochOffGrid };
const tai_minus_gps_s = 19.0;
const absent_clock_us = 999999.999999;
const bad_clock_us = 999999.0;

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
            .bds => GpsTime.fromGpsCalendar(cal).addMs(time.bds_offset_ms),
            .tai => GpsTime.fromGpsCalendar(cal).addSeconds(-tai_minus_gps_s),
        };
    }
};

pub const File = struct {
    interval_s: f64,
    samples: []const Sample,
};

pub fn onGrid(t: GpsTime, t0: GpsTime, interval_s: f64) bool {
    const k = t.secondsSince(t0) / interval_s;
    return @abs(k - @round(k)) <= precise.grid_tolerance_s / interval_s;
}

pub fn parse(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, scope: diagnostics.Scope) diagnostics.InputError!File {
    var at: usize = 0;
    var issues: Rejections = .{};
    const result = parseRaw(arena, source, leap, &at, &issues) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedRecord => "an SP3 header or record boundary is malformed",
            error.UnsupportedTimeSystem => "the SP3 time system is unsupported",
            error.UnsupportedVersion => "the SP3 version is unsupported; expected version c or d",
            error.EpochOffGrid => "an SP3 epoch does not lie on the declared sampling grid",
        };
        try issues.report(scope);
        return scope.fail(.invalid_format, if (at == 0) null else .{ .text = .{ .line = std.math.lossyCast(u32, at) } }, "{s}", .{message});
    };
    try issues.report(scope);
    return result;
}

fn parseRaw(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, at: *usize, issues: *Rejections) Error!File {
    var lines = std.mem.splitScalar(u8, source, '\n');
    at.* = 1;
    const first = lines.next() orelse return error.MalformedRecord;
    if (first.len < 60 or first[0] != '#') return error.MalformedRecord;
    switch (first[1]) {
        'c', 'd' => {},
        'a', 'b' => return error.UnsupportedVersion,
        else => return error.MalformedRecord,
    }
    at.* = 2;
    const second = lines.next() orelse return error.MalformedRecord;
    if (!std.mem.startsWith(u8, second, "##")) return error.MalformedRecord;
    const interval_s = try fields.required(second, 24, 14);
    if (!(interval_s >= precise.min_interval_s and interval_s <= precise.max_interval_s)) return error.MalformedRecord;
    var time_system: ?TimeSystem = null;
    var line = lines.next();
    at.* += 1;
    while (line) |ln| : ({
        line = lines.next();
        at.* += 1;
    }) {
        if (ln.len == 0) continue;
        if (ln[0] == '*') break;
        if (ln[0] == 'P' or std.mem.startsWith(u8, ln, "EOF")) return error.MalformedRecord;
        if (std.mem.startsWith(u8, ln, "%c") and time_system == null) {
            const code = fields.column(ln, 9, 3) orelse return error.MalformedRecord;
            time_system = TimeSystem.fromCode(code) orelse return error.UnsupportedTimeSystem;
        }
    }
    const ts = time_system orelse return error.MalformedRecord;
    var samples: std.ArrayList(Sample) = .empty;
    var epoch: ?GpsTime = null;
    var first_epoch: ?GpsTime = null;
    while (line) |ln| : ({
        line = lines.next();
        at.* += 1;
    }) {
        if (ln.len == 0) continue;
        if (ln[0] == '*') {
            // A rejected epoch owns its whole block; its positions must never inherit the preceding epoch.
            epoch = null;
            var rejected = issue(ln, at.*, "SP3 epoch");
            const cal = calendar(ln, &rejected) catch {
                try issues.add(arena, rejected);
                continue;
            };
            const t = ts.toGps(cal, leap);
            if (first_epoch) |t0| {
                if (!onGrid(t, t0, interval_s)) return error.EpochOffGrid;
            } else first_epoch = t;
            epoch = t;
            continue;
        }
        if (std.mem.startsWith(u8, ln, "EOF")) break;
        if (ln[0] == 'V' or std.mem.startsWith(u8, ln, "EP") or std.mem.startsWith(u8, ln, "EV")) continue;
        if (ln[0] != 'P') return error.MalformedRecord;
        const t = epoch orelse continue;
        var rejected = issue(ln, at.*, "SP3 position");
        const sat = satellite(ln, &rejected) catch {
            try issues.add(arena, rejected);
            continue;
        } orelse {
            issues.ignore();
            continue;
        };
        rejected.system = sat.system;
        const sample = position(ln, sat, t, &rejected) catch {
            try issues.add(arena, rejected);
            continue;
        };
        if (sample) |value| try samples.append(arena, value);
    }
    return .{ .interval_s = interval_s, .samples = samples.items };
}

fn issue(line: []const u8, line_number: usize, message: []const u8) Rejection {
    return .{ .system = null, .named = .{ .label = line[0..@min(line.len, 80)] }, .message = message, .location = .{ .text = .{ .line = std.math.lossyCast(u32, line_number) } } };
}

fn calendar(line: []const u8, rejected: *Rejection) RecordError!civil.Utc {
    const cal: civil.Utc = .{
        .year = try fields.integerToken(i32, rejected, "year", fields.column(line, 3, 4)),
        .month = try fields.integerToken(u8, rejected, "month", fields.column(line, 8, 2)),
        .day = try fields.integerToken(u8, rejected, "day", fields.column(line, 11, 2)),
        .hour = try fields.integerToken(u8, rejected, "hour", fields.column(line, 14, 2)),
        .minute = try fields.integerToken(u8, rejected, "minute", fields.column(line, 17, 2)),
        .second = try fields.numberToken(rejected, "second", fields.column(line, 20, 11)),
    };
    if (!fields.calendarInRange(cal)) return rejected.fail("epoch", fields.column(line, 3, 28), .implausible);
    return cal;
}

fn satellite(line: []const u8, rejected: *Rejection) RecordError!?gnss_types.SatId {
    if (line.len < 4) return rejected.fail("satellite", fields.column(line, 1, 3), .blank);
    const name = line[1..4];
    if (!std.ascii.isUpper(name[0])) return rejected.fail("satellite", name, .malformed);
    const system = gnss_types.System.fromRinexLetter(name[0]) orelse return null;
    rejected.system = system;
    const prn = try fields.integerToken(u32, rejected, "satellite", std.mem.trim(u8, name[1..], " "));
    if (prn == 0) return rejected.fail("satellite", name, .implausible);
    return gnss_types.SatId.fromPrn(system, prn) catch null;
}

fn positionValue(line: []const u8, start: usize, name: [:0]const u8, rejected: *Rejection) RecordError!f64 {
    const token = fields.column(line, start, 14) orelse return rejected.fail(name, null, .blank);
    return if (token.len == 0) 0 else fields.numberToken(rejected, name, token);
}

fn position(line: []const u8, sat: gnss_types.SatId, t: GpsTime, rejected: *Rejection) RecordError!?Sample {
    const x = try positionValue(line, 4, "x_km", rejected);
    const y = try positionValue(line, 18, "y_km", rejected);
    const z = try positionValue(line, 32, "z_km", rejected);
    if (x == 0 and y == 0 and z == 0) return null;
    const pos: [3]f64 = .{ x * 1e3, y * 1e3, z * 1e3 };
    if (!precise.positionInRange(pos)) return rejected.fail("position", fields.column(line, 4, 42), .implausible);
    const clock_raw = if (line.len >= 60) try positionValue(line, 46, "clock_us", rejected) else absent_clock_us;
    if (!(clock_raw > -bad_clock_us and clock_raw < bad_clock_us + 1)) return rejected.fail("clock_us", fields.column(line, 46, 14), .implausible);
    return .{ .sat = sat, .t = t, .pos = pos, .clock_s = if (clock_raw >= bad_clock_us) null else clock_raw * 1e-6 };
}
