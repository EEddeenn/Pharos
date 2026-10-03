const std = @import("std");
const field = @import("../../../codec.zig").field;
const time = @import("../../../core.zig").time;
const records = @import("../../records.zig");
const auxiliary = @import("../../auxiliary.zig");
const bds_records = @import("../records.zig");
const constants = @import("../constants.zig");
const sources = @import("sources.zig");
const almanac_reference = @import("../../almanac_reference.zig");

const info_bits = @import("word.zig").info_bits;
const sowRow = sources.sowRow;
const rev = sources.rev;
const reserved = sources.reserved;
const Alm = records.KeplerAlmanac;

pub const AlmPage = struct { alm: ?Alm, pnum: u7, am_id: u2, geo: bool };

pub fn representable(a: Alm, geo: bool) bool {
    return almanacMisfit(a, geo) == null;
}

pub fn almanacMisfit(a: Alm, geo: bool) ?[:0]const u8 {
    if (!bds_records.almanacTimeFits(a.toa)) return "toa";
    return field.misfit(AlmPage, &almanac, &.{ .alm = a, .pnum = 0, .am_id = 0, .geo = geo });
}

pub const HealthPage = struct { pnum: u7, hea: [19]u9, wna: u8, toa: u8, am_id: u2 };

pub const UtcPage = struct { pnum: u7, a0: f64, a1: f64, delta_tls: i16, delta_tlsf: i16, wn_lsf: u8, dn: i16 };

pub fn utcFromParams(params: ?auxiliary.UtcParams, t: time.GpsTime) ?UtcPage {
    const utc_params = params orelse return null;
    if (utc_params.a2 != 0) return null;
    const leap = bds_records.bdtLeap(utc_params.leap orelse return null) orelse return null;
    const dt: f64 = @floatFromInt((t.inScale(.bds).period - utc_params.wn_t) * time.s_per_week - utc_params.tot_s);
    return .{
        .pnum = 0,
        .a0 = utc_params.a0 + utc_params.a1 * dt,
        .a1 = utc_params.a1,
        .delta_tls = leap.delta_tls,
        .delta_tlsf = leap.delta_tlsf,
        .wn_lsf = @truncate(leap.wn_lsf),
        .dn = leap.dn,
    };
}

pub const OffsetPage = struct { pnum: u7, a0gps: f64, a1gps: f64, a0gal: f64, a1gal: f64, a0glo: f64, a1glo: f64 };

pub fn offsetsFromParams(params: [3]?auxiliary.TimeOffset, t: time.GpsTime) ?OffsetPage {
    const start = time.GpsTime.fromScaleWeekMs(.bds, t.inScale(.bds).period, 0, 0);
    const sow = t.secondsSince(start);
    var a0: [3]f64 = undefined;
    var a1: [3]f64 = undefined;
    for (params, 0..) |entry, i| {
        const p = entry orelse return null;
        const reference = p.reference orelse return null;
        if (p.a2 != 0) return null;
        a1[i] = @round(p.a1 * sources.tenths_of_ns_per_s) / sources.tenths_of_ns_per_s;
        a0[i] = p.a0 + p.a1 * t.secondsSince(reference) - a1[i] * sow;
    }
    return .{ .pnum = 0, .a0gps = a0[0], .a1gps = a1[0], .a0gal = a0[1], .a1gal = a1[1], .a0glo = a0[2], .a1glo = a1[2] };
}

pub const Filler = struct { pnum: u7 = 0, am_id: u2 = 0 };

const A = field.Field(AlmPage);

fn almF(comptime name: []const u8) fn (*const AlmPage) f64 {
    return struct {
        fn f(p: *const AlmPage) f64 {
            const a = p.alm orelse return 0;
            return @field(a, name);
        }
    }.f;
}
fn almDeltaI(p: *const AlmPage) f64 {
    const a = p.alm orelse return 0;
    const ref = constants.almanacInclinationReference(p.geo);
    return a.i0 - ref;
}
fn almToa(p: *const AlmPage) i64 {
    const a = p.alm orelse return 0;
    return a.toa.inScale(.bds).ms / almanac_reference.toa_step_ms;
}

pub const almanac = [_]A{
    sowRow(AlmPage),
    rev(AlmPage),
    .{ .name = "pnum", .width = 7, .src = .{ .field = "pnum" } },
    .{ .name = "sqrt_a", .width = 24, .scale_log2 = -11, .src = .{ .computed = &almF("sqrt_a") } },
    .{ .name = "af1", .width = 11, .repr = .twos, .scale_log2 = -38, .src = .{ .computed = &almF("af1") } },
    .{ .name = "af0", .width = 11, .repr = .twos, .scale_log2 = -20, .src = .{ .computed = &almF("af0") } },
    .{ .name = "omega0", .width = 24, .repr = .twos, .scale_log2 = -23, .semicircles = true, .periodic = true, .src = .{ .computed = &almF("omega0") } },
    .{ .name = "ecc", .width = 17, .scale_log2 = -21, .src = .{ .computed = &almF("ecc") } },
    .{ .name = "delta_i", .width = 16, .repr = .twos, .scale_log2 = -19, .semicircles = true, .src = .{ .computed = &almDeltaI } },
    .{ .name = "toa", .width = 8, .src = .{ .computed_int = &almToa } },
    .{ .name = "omega_dot", .width = 17, .repr = .twos, .scale_log2 = -38, .semicircles = true, .src = .{ .computed = &almF("omega_dot") } },
    .{ .name = "w", .width = 24, .repr = .twos, .scale_log2 = -23, .semicircles = true, .periodic = true, .src = .{ .computed = &almF("w") } },
    .{ .name = "m0", .width = 24, .repr = .twos, .scale_log2 = -23, .semicircles = true, .periodic = true, .src = .{ .computed = &almF("m0") } },
    .{ .name = "am_id", .width = 2, .src = .{ .field = "am_id" } },
};

const H = field.Field(HealthPage);

fn heaAt(comptime k: usize) fn (*const HealthPage) i64 {
    return struct {
        fn f(p: *const HealthPage) i64 {
            return p.hea[k];
        }
    }.f;
}
fn heaRows(comptime n: usize) [n]H {
    var rows: [n]H = undefined;
    for (&rows, 0..) |*row, k| row.* = .{ .name = std.fmt.comptimePrint("hea_{d}", .{k + 1}), .width = 9, .src = .{ .computed_int = &heaAt(k) } };
    return rows;
}
const health_head = [_]H{ sowRow(HealthPage), rev(HealthPage), .{ .name = "pnum", .width = 7, .src = .{ .field = "pnum" } } };

pub const health7 = health_head ++ heaRows(19) ++ [_]H{reserved(HealthPage, "reserved_h7", 7)};
pub const health8 = health_head ++ heaRows(11) ++ [_]H{
    .{ .name = "wna", .width = 8, .src = .{ .field = "wna" } },
    .{ .name = "toa", .width = 8, .src = .{ .field = "toa" } },
    reserved(HealthPage, "reserved_h8", 63),
};
pub const health24 = health_head ++ heaRows(13) ++ [_]H{ .{ .name = "am_id", .width = 2, .src = .{ .field = "am_id" } }, reserved(HealthPage, "reserved_h24", 59) };

const U = field.Field(UtcPage);

pub const utc = [_]U{
    sowRow(UtcPage),
    rev(UtcPage),
    .{ .name = "pnum", .width = 7, .src = .{ .field = "pnum" } },
    .{ .name = "delta_tls", .width = 8, .repr = .twos, .src = .{ .field = "delta_tls" } },
    .{ .name = "delta_tlsf", .width = 8, .repr = .twos, .src = .{ .field = "delta_tlsf" } },
    .{ .name = "wn_lsf", .width = 8, .src = .{ .field = "wn_lsf" } },
    .{ .name = "a0", .width = 32, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "a0" } },
    .{ .name = "a1", .width = 24, .repr = .twos, .scale_log2 = -50, .src = .{ .field = "a1" } },
    .{ .name = "dn", .width = 8, .src = .{ .field = "dn" } },
} ++ field.reservedRows(UtcPage, "reserved_utc", 90);

const O = field.Field(OffsetPage);

fn offsetUnits(comptime name: []const u8) fn (*const OffsetPage) f64 {
    return struct {
        fn f(p: *const OffsetPage) f64 {
            return @field(p, name) * sources.tenths_of_ns_per_s;
        }
    }.f;
}

pub const offsets = [_]O{
    sowRow(OffsetPage),
    rev(OffsetPage),
    .{ .name = "pnum", .width = 7, .src = .{ .field = "pnum" } },
    reserved(OffsetPage, "reserved_9_head", 30),
    .{ .name = "a0gps", .width = 14, .repr = .twos, .src = .{ .computed = &offsetUnits("a0gps") } },
    .{ .name = "a1gps", .width = 16, .repr = .twos, .src = .{ .computed = &offsetUnits("a1gps") } },
    .{ .name = "a0gal", .width = 14, .repr = .twos, .src = .{ .computed = &offsetUnits("a0gal") } },
    .{ .name = "a1gal", .width = 16, .repr = .twos, .src = .{ .computed = &offsetUnits("a1gal") } },
    .{ .name = "a0glo", .width = 14, .repr = .twos, .src = .{ .computed = &offsetUnits("a0glo") } },
    .{ .name = "a1glo", .width = 16, .repr = .twos, .src = .{ .computed = &offsetUnits("a1glo") } },
} ++ field.reservedRows(OffsetPage, "reserved_9", 58);

const F = field.Field(Filler);
pub const reserved_page = [_]F{
    sowRow(Filler),
    rev(Filler),
    .{ .name = "pnum", .width = 7, .src = .{ .field = "pnum" } },
} ++ field.reservedRows(Filler, "reserved_r", 176) ++ [_]F{.{ .name = "am_id", .width = 2, .src = .{ .field = "am_id" } }};
comptime {
    std.debug.assert(field.totalWidth(AlmPage, &almanac) == info_bits);
    for (.{ health7, health8, health24 }) |layout| std.debug.assert(field.totalWidth(HealthPage, &layout) == info_bits);
    std.debug.assert(field.totalWidth(UtcPage, &utc) == info_bits);
    std.debug.assert(field.totalWidth(OffsetPage, &offsets) == info_bits);
    std.debug.assert(field.totalWidth(Filler, &reserved_page) == info_bits);
}
