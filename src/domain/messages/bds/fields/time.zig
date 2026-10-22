const std = @import("std");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const auxiliary = @import("domain/navigation/system_data");
const bds_records = @import("domain/navigation/records/bds");
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

pub const Eop = struct {
    t_eop_16s: u16,
    xp_arcsec: f64,
    xp_rate_arcsec_day: f64,
    yp_arcsec: f64,
    yp_rate_arcsec_day: f64,
    dut1: f64,
    dut1_rate_s_day: f64,
};
pub const Bgto = struct {
    gnss_id: u3 = 0,
    wn_bgto: u13 = 0,
    t_bgto_16s: u16 = 0,
    a0_bgto: f64 = 0,
    a1_bgto: f64 = 0,
    a2_bgto: f64 = 0,
};

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

pub fn utcFromRecord(input: ?auxiliary.UtcParams) ?UtcCodes {
    const source = input orelse return null;
    const leap = bds_records.bdtLeap(source.leap orelse return null) orelse return null;
    if (source.tot_s % 16 != 0) return null;
    const candidate = utcCandidate(source, leap);
    return switch (field.prepare(Utc, &utc, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn eopFromRecord(input: ?auxiliary.Eop) ?EopCodes {
    const source = input orelse return null;
    const reference = source.reference.inScale(.bds);
    if (reference.ms % auxiliary.reference_step_ms != 0 or reference.sub_ms != 0) return null;
    if (source.xp_acc_arcsec_day2 != 0 or source.yp_acc_arcsec_day2 != 0 or source.dut1_acc_s_day2 != 0 or source.dut1 != .ut1_utc) return null;
    const candidate = eopCandidate(source);
    return switch (field.prepare(Eop, &eop, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn bgtoFromRecord(in: ?auxiliary.TimeOffset, id: u3) ?BgtoCodes {
    const offset = in orelse return null;
    const ref = (offset.reference orelse return null).inScale(.bds);
    if (ref.ms % auxiliary.reference_step_ms != 0 or ref.sub_ms != 0) return null;
    const candidate: Bgto = .{
        .gnss_id = id,
        .wn_bgto = @intCast(@mod(ref.period, time.week_modulus_13)),
        .t_bgto_16s = @intCast(ref.ms / auxiliary.reference_step_ms),
        .a0_bgto = offset.a0,
        .a1_bgto = offset.a1,
        .a2_bgto = offset.a2,
    };
    return switch (field.prepare(Bgto, &bgto, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

fn eopTime(e: *const Eop) i64 {
    return e.t_eop_16s;
}

comptime {
    std.debug.assert(field.totalWidth(Utc, &utc) == 97);
    std.debug.assert(field.totalWidth(Eop, &eop) == 138 and field.totalWidth(Bgto, &bgto) == 68);
}

pub const UtcCodes = field.Decoded(Utc, &utc);
pub const EopCodes = field.Decoded(Eop, &eop);
pub const BgtoCodes = field.Decoded(Bgto, &bgto);
pub const empty_bgto: BgtoCodes = field.project(Bgto, &bgto, &.{});

pub fn projectUtc(source: auxiliary.UtcParams) UtcCodes {
    return field.project(Utc, &utc, &utcCandidate(source, bds_records.projectBdtLeap(source.leap.?)));
}
pub fn eopCandidate(source: auxiliary.Eop) Eop {
    return .{ .t_eop_16s = @intCast(source.reference.inScale(.bds).ms / auxiliary.reference_step_ms), .xp_arcsec = source.xp_arcsec, .xp_rate_arcsec_day = source.xp_rate_arcsec_day, .yp_arcsec = source.yp_arcsec, .yp_rate_arcsec_day = source.yp_rate_arcsec_day, .dut1 = switch (source.dut1) {
        inline else => |seconds| seconds,
    }, .dut1_rate_s_day = source.dut1_rate_s_day };
}

pub fn projectEop(source: auxiliary.Eop) EopCodes {
    return field.project(Eop, &eop, &eopCandidate(source));
}

pub fn projectBgto(source: auxiliary.TimeOffset, id: u3) BgtoCodes {
    const reference = source.reference.?.inScale(.bds);
    return field.project(Bgto, &bgto, &.{ .gnss_id = id, .wn_bgto = @intCast(@mod(reference.period, time.week_modulus_13)), .t_bgto_16s = @intCast(reference.ms / auxiliary.reference_step_ms), .a0_bgto = source.a0, .a1_bgto = source.a1, .a2_bgto = source.a2 });
}

fn utcCandidate(source: auxiliary.UtcParams, leap: bds_records.BdtLeap) Utc {
    return .{ .a0 = source.a0, .a1 = source.a1, .a2 = source.a2, .delta_tls = leap.delta_tls, .tot_16s = @intCast(source.tot_s / 16), .wn_ot = @truncate(source.wn_t), .wn_lsf = @truncate(leap.wn_lsf), .dn = leap.dn, .delta_tlsf = leap.delta_tlsf };
}
