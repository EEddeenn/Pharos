const std = @import("std");
const core = @import("shared").core;
const fields = @import("../fields.zig");
const auxiliary = @import("shared").gnss.auxiliary;
const rinex_fields = @import("fields.zig");
const GpsTime = core.time.GpsTime;
const civil = core.civil;
const System = core.types.System;

const max_week_offset_s: f64 = 604_800;

const kinds = std.StaticStringMap(auxiliary.OffsetKind).initComptime(.{
    .{ "GPUT", .gput }, .{ "GAUT", .gaut }, .{ "BDUT", .bdut },
    .{ "GLUT", .glut }, .{ "GAGP", .gagp }, .{ "GLGP", .glgp },
    .{ "BDGP", .bdgp }, .{ "BDGA", .bdga }, .{ "BDGL", .bdgl },
});

pub fn systemOf(kind: auxiliary.OffsetKind) System {
    return switch (kind) {
        .gput => .gps,
        .gaut, .gagp => .gal,
        .bdut, .bdgp, .bdga, .bdgl => .bds,
        .glut, .glgp => .glo,
    };
}

pub fn message(name: []const u8) ?auxiliary.Message {
    const names = std.StaticStringMap(auxiliary.Message).initComptime(.{
        .{ "LNAV", .lnav }, .{ "CNVX", .cnvx }, .{ "D1D2", .d1d2 },
        .{ "IFNV", .ifnv }, .{ "FDMA", .fdma },
    });
    return names.get(name);
}

pub fn header(line: []const u8) fields.Error!?auxiliary.TimeOffset {
    const kind = if (std.mem.eql(u8, line[0..4], "GPGA")) auxiliary.OffsetKind.gagp else kinds.get(line[0..4]) orelse return null;
    const scale: ?core.time.WeekScale = switch (kind) {
        .bdgp, .bdga, .bdgl => return null,
        .glgp, .glut => null,
        .bdut => .bds,
        .gput, .gaut, .gagp => .gps,
    };
    var tokens = std.mem.tokenizeAny(u8, line[22..60], " ");
    const a1 = fields.float(tokens.next() orelse return error.MalformedRecord) orelse return error.MalformedRecord;
    const tot: i64 = std.fmt.parseInt(u32, tokens.next() orelse return error.MalformedRecord, 10) catch return error.MalformedRecord;
    const week = std.fmt.parseInt(u16, tokens.next() orelse return error.MalformedRecord, 10) catch return error.MalformedRecord;
    const a0 = try fields.required(line, 5, 17);
    const sign: f64 = if (kind == .glgp) -1 else 1;
    return .{
        .kind = kind,
        .source = null,
        .message = .header,
        .reference = if (scale) |s| GpsTime.fromScaleWeekMs(s, week, tot * 1000, 0) else null,
        .transmitted = null,
        .a0 = sign * a0,
        .a1 = sign * a1,
        .a2 = 0,
    };
}

fn Dated(comptime Record: type) type {
    return struct { epoch: civil.Utc, record: Record };
}

pub fn inSystem(system: System, nominal: GpsTime, leap: civil.Leap) GpsTime {
    return switch (system) {
        .gps, .gal => nominal,
        .bds => nominal.addMs(core.time.bds_offset_ms),
        .glo => GpsTime.fromUtc(leap, nominal.toCalendar()),
    };
}

fn transmitted(system: System, nominal: GpsTime, line: []const u8, leap: civil.Leap) fields.Error!GpsTime {
    const s = try fields.required(line, 4, 19);
    if (!(s > -max_week_offset_s and s < 2 * max_week_offset_s)) return error.MalformedRecord;
    const ms = s * 1000;
    const whole: i64 = @intFromFloat(@floor(ms));
    return inSystem(system, GpsTime.fromWeekMs(nominal.week(), whole, ms - @floor(ms)), leap);
}

pub fn sto(system: System, msg: auxiliary.Message, first: []const u8, second: []const u8, leap: civil.Leap) fields.Error!?Dated(auxiliary.TimeOffset) {
    if (first.len < 28) return error.MalformedRecord;
    const kind = kinds.get(first[24..28]) orelse return null;
    const epoch = try rinex_fields.calendar(first);
    const nominal = GpsTime.fromGpsCalendar(epoch);
    var out: auxiliary.TimeOffset = .{
        .kind = kind,
        .source = system,
        .message = msg,
        .reference = inSystem(system, nominal, leap),
        .transmitted = try transmitted(system, nominal, second, leap),
        .a0 = try fields.required(second, 23, 19),
        .a1 = try fields.required(second, 42, 19),
        .a2 = try rinex_fields.field(second, 61),
    };
    if (kind == .glgp) {
        out.a0 = -out.a0;
        out.a1 = -out.a1;
        out.a2 = -out.a2;
    }
    return .{ .epoch = epoch, .record = out };
}

pub fn eop(system: System, msg: auxiliary.Message, lines: [3][]const u8, leap: civil.Leap) fields.Error!Dated(auxiliary.Eop) {
    const epoch = try rinex_fields.calendar(lines[0]);
    const nominal = GpsTime.fromGpsCalendar(epoch);
    const dut1 = try fields.required(lines[2], 23, 19);
    return .{ .epoch = epoch, .record = .{
        .source = system,
        .message = msg,
        .reference = inSystem(system, nominal, leap),
        .transmitted = try transmitted(system, nominal, lines[2], leap),
        .xp_arcsec = try fields.required(lines[0], 23, 19),
        .xp_rate_arcsec_day = try fields.required(lines[0], 42, 19),
        .xp_acc_arcsec_day2 = try rinex_fields.field(lines[0], 61),
        .yp_arcsec = try fields.required(lines[1], 23, 19),
        .yp_rate_arcsec_day = try fields.required(lines[1], 42, 19),
        .yp_acc_arcsec_day2 = try rinex_fields.field(lines[1], 61),
        .dut1 = dut1,
        .dut1_kind = auxiliary.dut1KindOf(dut1),
        .dut1_rate_s_day = try fields.required(lines[2], 42, 19),
        .dut1_acc_s_day2 = try rinex_fields.field(lines[2], 61),
    } };
}
