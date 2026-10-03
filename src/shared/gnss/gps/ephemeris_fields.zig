const std = @import("std");
const field = @import("../../codec.zig").field;
const constants = @import("constants.zig");
const records = @import("../records.zig");
const accuracy = @import("accuracy.zig");
const gps_records = @import("records.zig");

pub const Parameters = struct {
    eph: @import("../kepler_parameters.zig").Parameters,
    wn: u13,
    top_s: u32,
    ura: accuracy.Ura = .{ .ed = 0, .ned0 = 0, .ned1 = 0, .ned2 = 0 },
    l1_health: bool = false,
    l2_health: bool = false,
    l5_health: bool = false,
    flags: ?gps_records.CnavFlags = null,
    integrity_status: ?bool = null,
    tgd: f64,
    isc_l1ca: f64,
    isc_l2c: f64,
    isc_l5i5: f64,
    isc_l5q5: f64,
    isc_l1cd: f64,
    isc_l1cp: f64,
    wn_op: u8,
};
const Sv = Parameters;

const S = field.Field(Sv);

fn topCount(s: *const Sv) i64 {
    return s.top_s / records.epoch_step_s;
}
fn toeCount(s: *const Sv) i64 {
    return s.eph.toe.msOfWeek() / records.epoch_step_ms;
}
fn deltaA(s: *const Sv) f64 {
    return s.eph.sqrt_a * s.eph.sqrt_a - constants.a_ref;
}
fn deltaOmegaDot(s: *const Sv) f64 {
    return s.eph.omega_dot - constants.omega_dot_ref * std.math.pi;
}

pub const top = [_]S{.{ .name = "top", .width = 11, .src = .{ .computed_int = &topCount } }};
pub const ura_ed = [_]S{.{ .name = "ura_ed", .width = 5, .repr = .twos, .renamed = true, .src = .{ .field = "ura.ed" } }};
pub const toe = [_]S{.{ .name = "toe", .width = 11, .src = .{ .computed_int = &toeCount } }};

pub const eph1 = [_]S{
    .{ .name = "delta_a", .width = 26, .repr = .twos, .scale_log2 = -9, .src = .{ .computed = &deltaA } },
    .{ .name = "a_dot", .width = 25, .repr = .twos, .scale_log2 = -21, .src = .{ .field = "eph.a_dot" } },
    .{ .name = "delta_n", .width = 17, .repr = .twos, .scale_log2 = -44, .semicircles = true, .src = .{ .field = "eph.delta_n" } },
    .{ .name = "delta_n_dot", .width = 23, .repr = .twos, .scale_log2 = -57, .semicircles = true, .src = .{ .field = "eph.delta_n_dot" } },
    .{ .name = "m0", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .periodic = true, .src = .{ .field = "eph.m0" } },
    .{ .name = "ecc", .width = 33, .scale_log2 = -34, .src = .{ .field = "eph.ecc" } },
    .{ .name = "w", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .periodic = true, .src = .{ .field = "eph.w" } },
};

pub const eph2 = [_]S{
    .{ .name = "omega0", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .periodic = true, .src = .{ .field = "eph.omega0" } },
    .{ .name = "i0", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .src = .{ .field = "eph.i0" } },
    .{ .name = "delta_omega_dot", .width = 17, .repr = .twos, .scale_log2 = -44, .semicircles = true, .src = .{ .computed = &deltaOmegaDot } },
    .{ .name = "idot", .width = 15, .repr = .twos, .scale_log2 = -44, .semicircles = true, .src = .{ .field = "eph.idot" } },
    .{ .name = "cis", .width = 16, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cis" } },
    .{ .name = "cic", .width = 16, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cic" } },
    .{ .name = "crs", .width = 24, .repr = .twos, .scale_log2 = -8, .src = .{ .field = "eph.crs" } },
    .{ .name = "crc", .width = 24, .repr = .twos, .scale_log2 = -8, .src = .{ .field = "eph.crc" } },
    .{ .name = "cus", .width = 21, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cus" } },
    .{ .name = "cuc", .width = 21, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cuc" } },
};

pub const ura_ned = [_]S{
    .{ .name = "ura_ned0", .width = 5, .repr = .twos, .renamed = true, .src = .{ .field = "ura.ned0" } },
    .{ .name = "ura_ned1", .width = 3, .renamed = true, .src = .{ .field = "ura.ned1" } },
    .{ .name = "ura_ned2", .width = 3, .renamed = true, .src = .{ .field = "ura.ned2" } },
};

pub const af = [_]S{
    .{ .name = "af0", .width = 26, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "eph.af0" } },
    .{ .name = "af1", .width = 20, .repr = .twos, .scale_log2 = -48, .src = .{ .field = "eph.af1" } },
    .{ .name = "af2", .width = 10, .repr = .twos, .scale_log2 = -60, .src = .{ .field = "eph.af2" } },
};

pub const tgd = [_]S{.{ .name = "tgd", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "tgd" } }};

pub const isc = [_]S{
    .{ .name = "isc_l1ca", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "isc_l1ca" } },
    .{ .name = "isc_l2c", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "isc_l2c" } },
    .{ .name = "isc_l5i5", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "isc_l5i5" } },
    .{ .name = "isc_l5q5", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "isc_l5q5" } },
};

pub const isc_l1c = [_]S{
    .{ .name = "isc_l1cp", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "isc_l1cp" } },
    .{ .name = "isc_l1cd", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "isc_l1cd" } },
};

pub const wn_op = [_]S{.{ .name = "wn_op", .width = 8, .src = .{ .field = "wn_op" } }};

pub fn misfit(sv: *const Sv) ?[:0]const u8 {
    inline for (.{ &top, &ura_ed, &toe, &eph1, &eph2, &ura_ned, &af, &tgd, &isc, &isc_l1c, &wn_op }) |rows| {
        if (field.misfit(Sv, rows, sv)) |name| return name;
    }
    return null;
}
