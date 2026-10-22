const std = @import("std");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const auxiliary = @import("domain/navigation/system_data");
pub const Utc = struct {
    a0: f64,
    a1: f64,
    a2: f64,
    delta_tls: i8,
    tot_s: u32,
    wn_ot: u13,
    wn_lsf: u13,
    dn: u8,
    delta_tlsf: i8,
};

pub const Eop = struct {
    t_eop: f64,
    pm_x: f64,
    pm_x_rate: f64,
    pm_y: f64,
    pm_y_rate: f64,
    ut_gps: f64,
    ut_gps_rate: f64,
};

pub const Ggto = struct {
    id: u3 = 0,
    t_ggto: f64 = 0,
    wn_ggto: u16 = 0,
    a0: f64 = 0,
    a1: f64 = 0,
    a2: f64 = 0,
};

const U = field.Field(Utc);

pub const utc_rows = [_]U{
    .{ .name = "a0", .width = 16, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "a0" } },
    .{ .name = "a1", .width = 13, .repr = .twos, .scale_log2 = -51, .src = .{ .field = "a1" } },
    .{ .name = "a2", .width = 7, .repr = .twos, .scale_log2 = -68, .src = .{ .field = "a2" } },
    .{ .name = "delta_tls", .width = 8, .repr = .twos, .src = .{ .field = "delta_tls" } },
    .{ .name = "tot", .width = 16, .scale_log2 = 4, .src = .{ .computed = &tot } },
    .{ .name = "wn_ot", .width = 13, .src = .{ .field = "wn_ot" } },
    .{ .name = "wn_lsf", .width = 13, .src = .{ .field = "wn_lsf" } },
    .{ .name = "dn", .width = 4, .src = .{ .field = "dn" } },
    .{ .name = "delta_tlsf", .width = 8, .repr = .twos, .src = .{ .field = "delta_tlsf" } },
};

const E = field.Field(Eop);
pub const eop_rows = [_]E{
    .{ .name = "t_eop", .width = 16, .scale_log2 = 4, .src = .{ .field = "t_eop" } },
    .{ .name = "pm_x", .width = 21, .repr = .twos, .scale_log2 = -20, .src = .{ .field = "pm_x" } },
    .{ .name = "pm_x_rate", .width = 15, .repr = .twos, .scale_log2 = -21, .src = .{ .field = "pm_x_rate" } },
    .{ .name = "pm_y", .width = 21, .repr = .twos, .scale_log2 = -20, .src = .{ .field = "pm_y" } },
    .{ .name = "pm_y_rate", .width = 15, .repr = .twos, .scale_log2 = -21, .src = .{ .field = "pm_y_rate" } },
    .{ .name = "ut_gps", .width = 31, .repr = .twos, .scale_log2 = -23, .src = .{ .field = "ut_gps" } },
    .{ .name = "ut_gps_rate", .width = 19, .repr = .twos, .scale_log2 = -25, .src = .{ .field = "ut_gps_rate" } },
};

const G = field.Field(Ggto);
pub const ggto_reference = [_]G{
    .{ .name = "t_ggto", .width = 16, .scale_log2 = 4, .src = .{ .field = "t_ggto" } },
    .{ .name = "wn_ggto", .width = 13, .src = .{ .field = "wn_ggto" } },
};
pub const ggto_id = [_]G{.{ .name = "id", .width = 3, .src = .{ .field = "id" } }};
pub const ggto_coefficients = [_]G{
    .{ .name = "a0", .width = 16, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "a0" } },
    .{ .name = "a1", .width = 13, .repr = .twos, .scale_log2 = -51, .src = .{ .field = "a1" } },
    .{ .name = "a2", .width = 7, .repr = .twos, .scale_log2 = -68, .src = .{ .field = "a2" } },
};

pub fn utcBlock(input: ?auxiliary.UtcParams) ?UtcCodes {
    const source = input orelse return null;
    if (source.leap == null or source.tot_s % 16 != 0) return null;
    const candidate = utcCandidate(source);
    return switch (field.prepare(Utc, &utc_rows, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn eopBlock(input: ?auxiliary.Eop, utc: ?auxiliary.UtcParams) ?EopCodes {
    const source = input orelse return null;
    const u = utc orelse return null;
    if (source.source != .gps or source.message != .cnvx) return null;
    if (source.reference.sub_ms != 0 or @mod(source.reference.ms, auxiliary.reference_step_ms) != 0) return null;
    if (source.reference.week() != u.wn_t or source.reference.msOfWeek() / 1000 != u.tot_s) return null;
    if (source.xp_acc_arcsec_day2 != 0 or source.yp_acc_arcsec_day2 != 0 or source.dut1_acc_s_day2 != 0) return null;
    if (source.dut1 == .ut1_utc and (u.a2 != 0 or u.leap == null)) return null;
    const candidate = eopCandidate(source, u);
    return switch (field.prepare(Eop, &eop_rows, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn ggtoBlock(in: ?auxiliary.TimeOffset, t: time.GpsTime) ?GgtoBlock {
    const g = in orelse return null;
    const id: u3, const sign: f64 = switch (g.kind) {
        .gagp => .{ 1, -1 },
        .glgp => .{ 2, 1 },
        else => return null,
    };
    const aligned_reference: ?time.GpsTime = blk: {
        const reference = g.reference orelse break :blk null;
        if (reference.sub_ms != 0 or @mod(reference.ms, auxiliary.reference_step_ms) != 0) break :blk null;
        break :blk reference;
    };
    const epoch = aligned_reference orelse blk: {
        if (g.a1 != 0 or g.a2 != 0) return null;
        break :blk time.GpsTime.fromWeekMs(t.week(), 0, 0);
    };
    const out: Ggto = .{
        .id = id,
        .t_ggto = epoch.sow(),
        .wn_ggto = @intCast(@mod(epoch.week(), time.week_modulus_13)),
        .a0 = sign * g.a0,
        .a1 = sign * g.a1,
        .a2 = sign * g.a2,
    };
    const block = switch (field.prepare(Ggto, &ggto_rows, &out)) {
        .codes => |codes| codes,
        .badfield => return null,
    };
    return .{ .anchor = if (aligned_reference != null) .record_reference else .week_start, .block = block };
}

fn tot(u: *const Utc) f64 {
    return @floatFromInt(u.tot_s);
}

comptime {
    std.debug.assert(field.totalWidth(Utc, &utc_rows) == 98);
    std.debug.assert(field.totalWidth(Eop, &eop_rows) == 138);
    std.debug.assert(field.totalWidth(Ggto, &ggto_reference) + field.totalWidth(Ggto, &ggto_id) + field.totalWidth(Ggto, &ggto_coefficients) == 68);
}

const ggto_rows = ggto_reference ++ ggto_id ++ ggto_coefficients;

pub const UtcCodes = field.Decoded(Utc, &utc_rows);
pub const EopCodes = field.Decoded(Eop, &eop_rows);
pub const GgtoCodes = field.Decoded(Ggto, &ggto_rows);
pub const GgtoAnchor = enum { record_reference, week_start };
pub const GgtoBlock = struct { anchor: GgtoAnchor, block: GgtoCodes };
pub const empty_ggto: GgtoCodes = field.project(Ggto, &ggto_rows, &.{});

pub fn projectUtc(source: auxiliary.UtcParams) UtcCodes {
    return field.project(Utc, &utc_rows, &utcCandidate(source));
}

pub fn projectEop(source: auxiliary.Eop, utc: auxiliary.UtcParams) EopCodes {
    return field.project(Eop, &eop_rows, &eopCandidate(source, utc));
}

pub fn projectGgto(source: auxiliary.TimeOffset, epoch: time.GpsTime) GgtoCodes {
    const id: u3, const sign: f64 = switch (source.kind) {
        .gagp => .{ 1, -1 },
        .glgp => .{ 2, 1 },
        else => unreachable,
    };
    return field.project(Ggto, &ggto_rows, &.{ .id = id, .t_ggto = epoch.sow(), .wn_ggto = @intCast(@mod(epoch.week(), time.week_modulus_13)), .a0 = sign * source.a0, .a1 = sign * source.a1, .a2 = sign * source.a2 });
}

fn utcCandidate(source: auxiliary.UtcParams) Utc {
    const leap = source.leap.?;
    return .{ .a0 = source.a0, .a1 = source.a1, .a2 = source.a2, .delta_tls = leap.delta_tls, .tot_s = source.tot_s, .wn_ot = @truncate(source.wn_t), .wn_lsf = @truncate(leap.wn_lsf), .dn = leap.dn, .delta_tlsf = leap.delta_tlsf };
}

fn eopCandidate(source: auxiliary.Eop, utc: auxiliary.UtcParams) Eop {
    var out: Eop = .{ .t_eop = source.reference.sow(), .pm_x = source.xp_arcsec, .pm_x_rate = source.xp_rate_arcsec_day, .pm_y = source.yp_arcsec, .pm_y_rate = source.yp_rate_arcsec_day, .ut_gps = undefined, .ut_gps_rate = source.dut1_rate_s_day };
    switch (source.dut1) {
        .ut1_gpst => |seconds| out.ut_gps = seconds,
        .ut1_utc => |seconds| {
            const leap = utc.leap.?;
            const count: f64 = @floatFromInt(if (source.reference.minusSeconds(utc.a0).lessThan(leap.eventAt())) leap.delta_tls else leap.delta_tlsf);
            out.ut_gps = seconds - (count + utc.a0);
            out.ut_gps_rate -= time.s_per_day * utc.a1;
        },
    }
    return out;
}
