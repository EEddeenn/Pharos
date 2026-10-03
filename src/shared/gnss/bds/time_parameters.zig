const std = @import("std");
const codec = @import("../../codec.zig");
const time = @import("../../core.zig").time;
const field = codec.field;
const auxiliary = @import("../auxiliary.zig");
const records = @import("records.zig");

pub const Utc = struct {
    a0: f64,
    a1: f64,
    a2: f64,
    delta_tls: i16,
    tot_16s: u16,
    wn_ot: u13,
    wn_lsf: u13,
    dn: i16,
    delta_tlsf: i16,
};

pub const Eop = auxiliary.Eop;

pub const Bgto = struct {
    gnss_id: u3 = 0,
    wn_bgto: u13 = 0,
    t_bgto_16s: u16 = 0,
    a0_bgto: f64 = 0,
    a1_bgto: f64 = 0,
    a2_bgto: f64 = 0,
};

pub fn utcFromRecord(in: ?auxiliary.UtcParams) ?Utc {
    const u = in orelse return null;
    const schedule = u.leap orelse return null;
    if (u.tot_s % 16 != 0) return null;
    const leap = records.bdtLeap(schedule) orelse return null;
    return .{
        .a0 = u.a0,
        .a1 = u.a1,
        .a2 = u.a2,
        .delta_tls = leap.delta_tls,
        .tot_16s = @intCast(u.tot_s / 16),
        .wn_ot = @truncate(u.wn_t),
        .wn_lsf = @truncate(leap.wn_lsf),
        .dn = leap.dn,
        .delta_tlsf = leap.delta_tlsf,
    };
}

pub fn eopFromRecord(in: ?Eop) ?Eop {
    const e = in orelse return null;
    const ref = e.reference.inScale(.bds);
    if (ref.ms % auxiliary.reference_step_ms != 0 or ref.sub_ms != 0) return null;
    if (e.xp_acc_arcsec_day2 != 0 or e.yp_acc_arcsec_day2 != 0 or e.dut1_acc_s_day2 != 0) return null;
    return e;
}

pub fn bgtoFromRecord(in: ?auxiliary.TimeOffset, id: u3) ?Bgto {
    const offset = in orelse return null;
    const ref = (offset.reference orelse return null).inScale(.bds);
    if (ref.ms % auxiliary.reference_step_ms != 0 or ref.sub_ms != 0) return null;
    return .{
        .gnss_id = id,
        .wn_bgto = @intCast(@mod(ref.period, time.week_modulus_13)),
        .t_bgto_16s = @intCast(ref.ms / auxiliary.reference_step_ms),
        .a0_bgto = offset.a0,
        .a1_bgto = offset.a1,
        .a2_bgto = offset.a2,
    };
}

fn eopTime(e: *const Eop) i64 {
    return e.reference.inScale(.bds).ms / auxiliary.reference_step_ms;
}

pub const utc = [_]field.Field(Utc){
    .{ .name = "a0utc", .width = 16, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "a0" }, .renamed = true },
    .{ .name = "a1utc", .width = 13, .repr = .twos, .scale_log2 = -51, .src = .{ .field = "a1" }, .renamed = true },
    .{ .name = "a2utc", .width = 7, .repr = .twos, .scale_log2 = -68, .src = .{ .field = "a2" }, .renamed = true },
    .{ .name = "delta_tls", .width = 8, .repr = .twos, .src = .{ .field = "delta_tls" } },
    .{ .name = "tot", .width = 16, .src = .{ .field = "tot_16s" }, .renamed = true },
    .{ .name = "wn_ot", .width = 13, .src = .{ .field = "wn_ot" } },
    .{ .name = "wn_lsf", .width = 13, .src = .{ .field = "wn_lsf" } },
    .{ .name = "dn", .width = 3, .src = .{ .field = "dn" } },
    .{ .name = "delta_tlsf", .width = 8, .repr = .twos, .src = .{ .field = "delta_tlsf" } },
};

pub const eop = [_]field.Field(Eop){
    .{ .name = "t_eop", .width = 16, .src = .{ .computed_int = &eopTime } },
    .{ .name = "xp", .width = 21, .repr = .twos, .scale_log2 = -20, .src = .{ .field = "xp_arcsec" }, .renamed = true },
    .{ .name = "xp_rate", .width = 15, .repr = .twos, .scale_log2 = -21, .src = .{ .field = "xp_rate_arcsec_day" }, .renamed = true },
    .{ .name = "yp", .width = 21, .repr = .twos, .scale_log2 = -20, .src = .{ .field = "yp_arcsec" }, .renamed = true },
    .{ .name = "yp_rate", .width = 15, .repr = .twos, .scale_log2 = -21, .src = .{ .field = "yp_rate_arcsec_day" }, .renamed = true },
    .{ .name = "dut1", .width = 31, .repr = .twos, .scale_log2 = -24, .src = .{ .field = "dut1" } },
    .{ .name = "dut1_rate", .width = 19, .repr = .twos, .scale_log2 = -25, .src = .{ .field = "dut1_rate_s_day" }, .renamed = true },
};

pub const bgto = [_]field.Field(Bgto){
    .{ .name = "gnss_id", .width = 3, .src = .{ .field = "gnss_id" } },
    .{ .name = "wn_bgto", .width = 13, .src = .{ .field = "wn_bgto" } },
    .{ .name = "t_bgto", .width = 16, .src = .{ .field = "t_bgto_16s" }, .renamed = true },
    .{ .name = "a0_bgto", .width = 16, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "a0_bgto" } },
    .{ .name = "a1_bgto", .width = 13, .repr = .twos, .scale_log2 = -51, .src = .{ .field = "a1_bgto" } },
    .{ .name = "a2_bgto", .width = 7, .repr = .twos, .scale_log2 = -68, .src = .{ .field = "a2_bgto" } },
};

comptime {
    std.debug.assert(field.totalWidth(Utc, &utc) == 97);
    std.debug.assert(field.totalWidth(Eop, &eop) == 138 and field.totalWidth(Bgto, &bgto) == 68);
}
