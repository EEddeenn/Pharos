const std = @import("std");
const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const auxiliary = @import("../auxiliary.zig");

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

pub fn utcBlock(in: ?auxiliary.UtcParams) ?Utc {
    const u = in orelse return null;
    const leap = u.leap orelse return null;
    if (u.tot_s % 16 != 0) return null;
    const out: Utc = .{
        .a0 = u.a0,
        .a1 = u.a1,
        .a2 = u.a2,
        .delta_tls = leap.delta_tls,
        .tot_s = u.tot_s,
        .wn_ot = @truncate(u.wn_t),
        .wn_lsf = @truncate(leap.wn_lsf),
        .dn = leap.dn,
        .delta_tlsf = leap.delta_tlsf,
    };
    return if (field.fits(Utc, &utc_rows, &out)) out else null;
}

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

pub fn eopBlock(in: ?auxiliary.Eop, utc: ?auxiliary.UtcParams) ?Eop {
    const e = in orelse return null;
    const u = utc orelse return null;
    if (e.source != .gps or e.message != .cnvx) return null;
    if (e.reference.sub_ms != 0 or @mod(e.reference.ms, auxiliary.reference_step_ms) != 0) return null;
    if (e.reference.week() != u.wn_t or e.reference.msOfWeek() / 1000 != u.tot_s) return null;
    if (e.xp_acc_arcsec_day2 != 0 or e.yp_acc_arcsec_day2 != 0 or e.dut1_acc_s_day2 != 0) return null;

    var out: Eop = .{
        .t_eop = e.reference.sow(),
        .pm_x = e.xp_arcsec,
        .pm_x_rate = e.xp_rate_arcsec_day,
        .pm_y = e.yp_arcsec,
        .pm_y_rate = e.yp_rate_arcsec_day,
        .ut_gps = e.dut1,
        .ut_gps_rate = e.dut1_rate_s_day,
    };
    switch (e.dut1_kind orelse return null) {
        .ut1_utc => {
            if (u.a2 != 0) return null;
            const leap = u.leap orelse return null;
            const count: f64 = @floatFromInt(if (e.reference.minusSeconds(u.a0).lessThan(leap.eventAt())) leap.delta_tls else leap.delta_tlsf);
            out.ut_gps -= count + u.a0;
            out.ut_gps_rate -= time.s_per_day * u.a1;
        },
        .ut1_gpst => {},
    }
    return if (field.fits(Eop, &eop_rows, &out)) out else null;
}

pub fn ggtoBlock(in: ?auxiliary.TimeOffset, t: time.GpsTime) ?Ggto {
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
    return if (field.fits(Ggto, &ggto_reference ++ ggto_id ++ ggto_coefficients, &out)) out else null;
}

const U = field.Field(Utc);

fn tot(u: *const Utc) f64 {
    return @floatFromInt(u.tot_s);
}

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

comptime {
    std.debug.assert(field.totalWidth(Utc, &utc_rows) == 98);
    std.debug.assert(field.totalWidth(Eop, &eop_rows) == 138);
    std.debug.assert(field.totalWidth(Ggto, &ggto_reference) + field.totalWidth(Ggto, &ggto_id) + field.totalWidth(Ggto, &ggto_coefficients) == 68);
}
