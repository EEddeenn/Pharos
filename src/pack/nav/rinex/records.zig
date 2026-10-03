const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const types = core.types;
const civil = core.civil;
const iono = core.iono;
const GpsTime = core.time.GpsTime;
const records = gnss.records;
const auxiliary = gnss.auxiliary;
const record = @import("../record.zig");
const rinex_fields = @import("fields.zig");

const transmission_window_weeks = 2;
const Epoch = rinex_fields.Epoch;
const Lines = rinex_fields.Lines;

pub const Pools = struct {
    arena: std.mem.Allocator,
    leap: civil.Leap = .table,
    kepler: std.ArrayList(records.KeplerEphemeris) = .empty,
    glonass: std.ArrayList(records.GlonassEphemeris) = .empty,
    time_offsets: std.ArrayList(auxiliary.TimeOffset) = .empty,
    eops: std.ArrayList(auxiliary.Eop) = .empty,
    ions: std.ArrayList(Ion) = .empty,
    skipped: u32 = 0,
    rejected: std.ArrayList(Rejection) = .empty,
};

pub const Ion = struct { transmitted: GpsTime, set: iono.Broadcast };

pub const Rejection = struct {
    system: types.System,
    named: Named,
    message: []const u8,
    field: [:0]const u8 = "",
    reason: Reason = .implausible,
};

const Named = union(enum) { record: struct { prn: u32, epoch: civil.Utc }, label: []const u8 };

pub const Reason = enum { implausible, blank, mismatch, malformed };

pub fn rejectLine(pools: *Pools, sys: types.System, line: []const u8) std.mem.Allocator.Error!void {
    pools.skipped += 1;
    try pools.rejected.append(pools.arena, .{ .system = sys, .named = .{ .label = line[0..@min(line.len, 23)] }, .message = "", .reason = .malformed });
}

pub fn rejectMalformed(pools: *Pools, sys: types.System, prn: u32, ep: Epoch, message: []const u8) std.mem.Allocator.Error!void {
    try pools.rejected.append(pools.arena, .{ .system = sys, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = message, .reason = .malformed });
}

fn blankField(body: *record.Body, name: [:0]const u8) record.Blank {
    body.blank = name;
    return error.BlankField;
}

fn keplerFromBody(sat: types.SatId, ep: Epoch, body: *record.Body, c: record.Completion) record.Blank!records.KeplerEphemeris {
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

pub fn systemRecord(comptime sys: types.System) type {
    return switch (sys) {
        .gps => record.gps,
        .gal => record.galileo,
        .bds => record.bds,
        .glo => record.glonass,
    };
}

pub fn keplerRecord(comptime sys: types.System, pools: *Pools, kind: systemRecord(sys).Kind, prn: u32, ep: Epoch, lines: *Lines) std.mem.Allocator.Error!?records.KeplerEphemeris {
    const R = systemRecord(sys);
    var rows: [9][4]?f64 = undefined;
    const n = R.bodyLines(kind);
    for (rows[0..n]) |*row| row.* = rinex_fields.optionalBodyLine(lines) catch {
        try rejectMalformed(pools, sys, prn, ep, @tagName(kind));
        return null;
    };
    const sat = types.SatId.fromPrn(sys, prn) catch return null;
    var body: record.Body = .{ .rows = rows[0..n] };
    const completion = R.complete(&body, kind, GpsTime.fromGpsCalendar(ep.utc)) catch |e| return blankOrSkip(pools, e, sys, prn, ep, @tagName(kind), body.blank);
    var rec = keplerFromBody(sat, ep, &body, completion) catch |e| return blankOrSkip(pools, e, sys, prn, ep, @tagName(kind), body.blank);
    rec.transmitted = transmissionTime(&rec, n, rows[n - 1][0]);
    if (gnss.plausible.kepler(&rec)) |name| {
        try pools.rejected.append(pools.arena, .{ .system = sys, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = rec.source().rinexName(sat), .field = name });
        return null;
    }
    return rec;
}

fn transmissionTime(rec: *const records.KeplerEphemeris, body_lines: usize, value: ?f64) ?GpsTime {
    const s = value orelse return null;
    if (!(s > -core.time.s_per_week and s < transmission_window_weeks * core.time.s_per_week)) return null;
    const reference = (if (body_lines == 7) rec.toe else rec.toc).inScale(rec.weekScale());
    return GpsTime.fromScaleWeekMs(reference.scale, reference.period, @intFromFloat(@round(s * 1000)), 0);
}

fn blankOrSkip(pools: *Pools, e: record.Error, sys: types.System, prn: u32, ep: Epoch, message: []const u8, name: [:0]const u8) std.mem.Allocator.Error!?records.KeplerEphemeris {
    if (e == error.BlankField) try pools.rejected.append(pools.arena, .{ .system = sys, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = message, .field = name, .reason = .blank });
    return null;
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
    const sat = types.SatId.fromPrn(.glo, prn) catch return null;
    var head: [2]f64 = undefined;
    inline for (.{ "tau_n", "gamma_n" }, 0..) |name, i| head[i] = ep.head[i] orelse {
        try pools.rejected.append(pools.arena, .{ .system = .glo, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = "fdma", .field = name, .reason = .blank });
        return null;
    };
    const field: [:0]const u8, const reason: Reason = switch (record.glonass.fromRinex(sat, ep.utc, head, body, fourth, pools.leap)) {
        .record => |rec| return rec,
        .misfit => |name| .{ name, .implausible },
        .blank => |name| .{ name, .blank },
    };
    try pools.rejected.append(pools.arena, .{ .system = .glo, .named = .{ .record = .{ .prn = prn, .epoch = ep.utc } }, .message = "fdma", .field = field, .reason = reason });
    return null;
}
