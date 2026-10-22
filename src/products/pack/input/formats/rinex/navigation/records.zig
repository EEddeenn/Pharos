const std = @import("std");
const gps_records = @import("products/pack/input/navigation/records/gps");
const galileo_records = @import("products/pack/input/navigation/records/galileo");
const bds_records = @import("products/pack/input/navigation/records/bds");
const navigation = @import("products/pack/input/admission/navigation");
const time = @import("domain/time/gps");
const glonass_records = @import("products/pack/input/navigation/records/glonass");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const records = @import("domain/navigation/records");
const auxiliary = @import("domain/navigation/system_data");
const record = @import("products/pack/input/navigation/records/decode");
const rinex_fields = @import("products/pack/input/formats/rinex/navigation/fields");
const rejections = @import("products/pack/input/rejections");
const GpsTime = time.GpsTime;
const Epoch = rinex_fields.Epoch;
const Lines = rinex_fields.Lines;

const transmission_window_weeks = 2;

pub const Pools = struct {
    arena: std.mem.Allocator,
    leap: civil.Leap = .table,
    kepler: std.ArrayList(records.KeplerEphemeris) = .empty,
    glonass: std.ArrayList(records.GlonassEphemeris) = .empty,
    time_offsets: std.ArrayList(auxiliary.TimeOffset) = .empty,
    eops: std.ArrayList(auxiliary.Eop) = .empty,
    ions: std.ArrayList(Ion) = .empty,
    issues: rejections.Rejections = .{},
};

pub const Ion = struct { transmitted: GpsTime, set: ionosphere_model.SuppliedCoefficients };

pub const Rejection = rejections.Rejection;
pub const Reason = rejections.Reason;

pub fn rejectLine(pools: *Pools, sys: gnss_types.System, line: []const u8) std.mem.Allocator.Error!void {
    try pools.issues.add(pools.arena, .{ .system = sys, .named = .{ .label = line[0..@min(line.len, 23)] }, .message = "", .reason = .malformed });
}

pub fn rejectMalformed(pools: *Pools, sys: gnss_types.System, prn: u32, ep: Epoch, message: []const u8) std.mem.Allocator.Error!void {
    try pools.issues.add(pools.arena, .{ .system = sys, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = message, .reason = .malformed });
}

pub fn systemRecord(comptime sys: gnss_types.System) type {
    return switch (sys) {
        .gps => gps_records,
        .gal => galileo_records,
        .bds => bds_records,
        .glo => glonass_records,
    };
}

pub fn keplerRecord(comptime sys: gnss_types.System, pools: *Pools, kind: systemRecord(sys).Kind, prn: u32, ep: Epoch, lines: *Lines) std.mem.Allocator.Error!?records.KeplerEphemeris {
    const R = systemRecord(sys);
    const message = R.Kind.words.get(kind);
    var rows: [9][4]?f64 = undefined;
    var source_lines: [9][]const u8 = undefined;
    const n = R.bodyLines(kind);
    for (rows[0..n], source_lines[0..n]) |*row, *line| {
        line.* = rinex_fields.continuation(lines) orelse {
            try rejectMalformed(pools, sys, prn, ep, message);
            return null;
        };
        row.* = rinex_fields.bodyColumns(line.*) catch {
            try rejectMalformed(pools, sys, prn, ep, message);
            return null;
        };
    }
    const sat = gnss_types.SatId.fromPrn(sys, prn) catch {
        pools.issues.ignore();
        return null;
    };
    var body: record.Body = .{ .rows = rows[0..n], .source_lines = source_lines[0..n] };
    const completion = R.complete(&body, kind, GpsTime.fromGpsCalendar(ep.utc)) catch |e| return blankOrSkip(pools, e, sys, prn, ep, message, body);
    var rec = keplerFromBody(sat, ep, &body, completion) catch |e| return blankOrSkip(pools, e, sys, prn, ep, message, body);
    rec.transmitted = transmissionTime(&rec, n, rows[n - 1][0]);
    if (navigation.kepler(&rec)) |name| {
        try pools.issues.add(pools.arena, .{ .system = sys, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = rec.source().rinexName(sat), .field = name });
        return null;
    }
    return rec;
}

pub fn glonassBody(pools: *Pools, prn: u32, ep: Epoch, lines: *Lines) std.mem.Allocator.Error!?[3][4]?f64 {
    var body: [3][4]?f64 = undefined;
    for (&body) |*b| b.* = rinex_fields.optionalBodyLine(lines) catch {
        try rejectMalformed(pools, .glo, prn, ep, "fdma");
        return null;
    };
    return body;
}

pub fn glonassRecord(pools: *Pools, prn: u32, ep: Epoch, body: *const [3][4]?f64, fourth: ?[4]?f64) std.mem.Allocator.Error!?records.GlonassEphemeris {
    const sat = gnss_types.SatId.fromPrn(.glo, prn) catch {
        pools.issues.ignore();
        return null;
    };
    var head: [2]f64 = undefined;
    inline for (.{ "tau_n", "gamma_n" }, 0..) |name, i| head[i] = ep.head[i] orelse {
        try pools.issues.add(pools.arena, .{ .system = .glo, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = "fdma", .field = name, .reason = .blank });
        return null;
    };
    const field: [:0]const u8, const reason: Reason = switch (glonass_records.fromRinex(sat, ep.utc, head, body, fourth, pools.leap)) {
        .record => |rec| return rec,
        .misfit => |name| .{ name, .implausible },
        .blank => |name| .{ name, .blank },
        .non_integral => |name| .{ name, .non_integral },
    };
    try pools.issues.add(pools.arena, .{ .system = .glo, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = "fdma", .field = field, .reason = reason });
    return null;
}

fn blankField(body: *record.Body, name: [:0]const u8) record.Blank {
    body.field = name;
    body.failure = .blank;
    body.token = null;
    return error.BlankField;
}

fn keplerFromBody(sat: gnss_types.SatId, ep: Epoch, body: *record.Body, c: record.Completion) record.Blank!records.KeplerEphemeris {
    const af0 = ep.head[0] orelse return blankField(body, "af0");
    const af1 = ep.head[1] orelse return blankField(body, "af1");
    const af2 = ep.head[2] orelse return blankField(body, "af2");
    return .{
        .sat = sat,
        .iode = c.iode,
        .iodc = c.iodc,
        .toe = c.toe,
        .toc = c.toc,
        .top = c.top,
        .transmitted = null,
        .m0 = try body.get(0, 3, "m0"),
        .delta_n = try body.get(0, 2, "delta_n"),
        .delta_n_dot = c.delta_n_dot,
        .ecc = try body.get(1, 1, "ecc"),
        .sqrt_a = try body.get(1, 3, "sqrt_a"),
        .a_dot = c.a_dot,
        .omega0 = try body.get(2, 2, "omega0"),
        .i0 = try body.get(3, 0, "i0"),
        .w = try body.get(3, 2, "w"),
        .omega_dot = try body.get(3, 3, "omega_dot"),
        .idot = try body.get(4, 0, "idot"),
        .cuc = try body.get(1, 0, "cuc"),
        .cus = try body.get(1, 2, "cus"),
        .crc = try body.get(3, 1, "crc"),
        .crs = try body.get(0, 1, "crs"),
        .cic = try body.get(2, 1, "cic"),
        .cis = try body.get(2, 3, "cis"),
        .af0 = af0,
        .af1 = af1,
        .af2 = af2,
        .group_delay = c.group_delay,
        .extra = c.extra,
    };
}

fn transmissionTime(rec: *const records.KeplerEphemeris, body_lines: usize, value: ?f64) ?GpsTime {
    const s = value orelse return null;
    if (!(s > -time.s_per_week and s < transmission_window_weeks * time.s_per_week)) return null;
    const reference = (if (body_lines == 7) rec.toe else rec.toc).inScale(rec.weekScale());
    return GpsTime.fromScaleWeekMs(reference.scale, reference.period, @intFromFloat(@round(s * 1000)), 0);
}

fn blankOrSkip(pools: *Pools, _: record.Error, sys: gnss_types.System, prn: u32, ep: Epoch, message: []const u8, body: record.Body) std.mem.Allocator.Error!?records.KeplerEphemeris {
    const reason: Reason = switch (body.failure) {
        .blank => .blank,
        .malformed => .malformed,
        .non_integral => .non_integral,
        .out_of_range => .implausible,
    };
    try pools.issues.add(pools.arena, .{ .system = sys, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = message, .field = body.field, .reason = reason, .original_token = body.token });
    return null;
}
