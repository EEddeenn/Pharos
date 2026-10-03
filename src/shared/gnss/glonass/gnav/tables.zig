const std = @import("std");
const field = @import("../../../codec.zig").field;
const civil = @import("../../../core.zig").civil;
const records = @import("../records.zig");

const Eph = records.GlonassEphemeris;
const Alm = records.GlonassAlmanac;
const NoSource = field.NoSource;

pub const Ctx = struct {
    m: u4 = 0,
    slot: u5 = 0,

    tk_h: u5 = 0,
    tk_m: u6 = 0,
    tk_half: u1 = 0,

    p1: u2 = 0,
    p3: u1 = 0,
    ln: u1 = 0,

    tb: i64 = 0,
    p2: i64 = 0,
    nt: i64 = 0,
};

pub fn moscow(e: *const Eph, leap: civil.Leap) struct { tb: i64, p2: i64, nt: i64 } {
    const g = e.tb.toGlonass(leap);
    const tb = @divFloor(@as(i64, g.ms_of_day), records.tb_interval_ms);
    return .{ .tb = tb, .p2 = @mod(tb, 2), .nt = g.nt };
}

pub const TimeScale = struct { na: u11, n4: u5, tau_c: f64, tau_gps: f64 };

pub const String14 = struct { b1: f64, b2: f64, kp: u2 };

pub const data_bits = 76;

const E = field.Field(Eph);

fn km(comptime which: []const u8, comptime component: usize) fn (*const Eph) f64 {
    return struct {
        fn f(e: *const Eph) f64 {
            return @field(e, which)[component] / 1000.0;
        }
    }.f;
}
fn bn(e: *const Eph) i64 {
    return if (e.health) 0 else 4;
}
fn deltaTauN(e: *const Eph) f64 {
    return e.delta_tau_n orelse 0;
}
fn ft(e: *const Eph) i64 {
    return e.ft orelse 0;
}
fn pWord(e: *const Eph) i64 {
    return e.p orelse 0;
}
fn p4(e: *const Eph) i64 {
    return @intFromBool(e.p4 orelse false);
}
fn satType(e: *const Eph) i64 {
    return e.m orelse 1;
}
fn slotOf(e: *const Eph) i64 {
    return e.sat.prn();
}

pub const string1 = [_]E{
    .{ .name = "m", .width = 4, .src = .{ .constant = 1 } },
    .{ .name = "reserved_1", .width = 2, .src = .reserved },
    .{ .name = "p1", .width = 2, .src = .{ .ctx = "p1" } },
    .{ .name = "tk_h", .width = 5, .src = .{ .ctx = "tk_h" } },
    .{ .name = "tk_m", .width = 6, .src = .{ .ctx = "tk_m" } },
    .{ .name = "tk_half", .width = 1, .src = .{ .ctx = "tk_half" } },
    .{ .name = "xdot", .width = 24, .repr = .sign_mag, .scale_log2 = -20, .src = .{ .computed = &km("vel", 0) } },
    .{ .name = "xdotdot", .width = 5, .repr = .sign_mag, .scale_log2 = -30, .src = .{ .computed = &km("acc", 0) } },
    .{ .name = "x", .width = 27, .repr = .sign_mag, .scale_log2 = -11, .src = .{ .computed = &km("pos", 0) } },
};

pub const string2 = [_]E{
    .{ .name = "m", .width = 4, .src = .{ .constant = 2 } },
    .{ .name = "bn", .width = 3, .src = .{ .computed_int = &bn } },
    .{ .name = "p2", .width = 1, .src = .{ .ctx = "p2" } },
    .{ .name = "tb", .width = 7, .src = .{ .ctx = "tb" } },
    .{ .name = "reserved_2", .width = 5, .src = .reserved },
    .{ .name = "ydot", .width = 24, .repr = .sign_mag, .scale_log2 = -20, .src = .{ .computed = &km("vel", 1) } },
    .{ .name = "ydotdot", .width = 5, .repr = .sign_mag, .scale_log2 = -30, .src = .{ .computed = &km("acc", 1) } },
    .{ .name = "y", .width = 27, .repr = .sign_mag, .scale_log2 = -11, .src = .{ .computed = &km("pos", 1) } },
};

pub const string3 = [_]E{
    .{ .name = "m", .width = 4, .src = .{ .constant = 3 } },
    .{ .name = "p3", .width = 1, .src = .{ .ctx = "p3" } },
    .{ .name = "gamma_n", .width = 11, .repr = .sign_mag, .scale_log2 = -40, .src = .{ .field = "gamma_n" } },
    .{ .name = "reserved_3", .width = 1, .src = .reserved },
    .{ .name = "p", .width = 2, .src = .{ .computed_int = &pWord } },
    .{ .name = "ln", .width = 1, .src = .{ .ctx = "ln" } },
    .{ .name = "zdot", .width = 24, .repr = .sign_mag, .scale_log2 = -20, .src = .{ .computed = &km("vel", 2) } },
    .{ .name = "zdotdot", .width = 5, .repr = .sign_mag, .scale_log2 = -30, .src = .{ .computed = &km("acc", 2) } },
    .{ .name = "z", .width = 27, .repr = .sign_mag, .scale_log2 = -11, .src = .{ .computed = &km("pos", 2) } },
};

pub const string4 = [_]E{
    .{ .name = "m", .width = 4, .src = .{ .constant = 4 } },
    .{ .name = "tau_n", .width = 22, .repr = .sign_mag, .scale_log2 = -30, .src = .{ .field = "tau_n" } },
    .{ .name = "delta_tau_n", .width = 5, .repr = .sign_mag, .scale_log2 = -30, .src = .{ .computed = &deltaTauN } },
    .{ .name = "en", .width = 5, .src = .{ .field = "en" } },
    .{ .name = "reserved_4a", .width = 14, .src = .reserved },
    .{ .name = "p4", .width = 1, .src = .{ .computed_int = &p4 } },
    .{ .name = "ft", .width = 4, .src = .{ .computed_int = &ft } },
    .{ .name = "reserved_4b", .width = 3, .src = .reserved },
    .{ .name = "nt", .width = 11, .src = .{ .ctx = "nt" } },
    .{ .name = "n", .width = 5, .src = .{ .computed_int = &slotOf } },
    .{ .name = "sat_type", .width = 2, .src = .{ .computed_int = &satType } },
};

const T = field.Field(TimeScale);
pub const string5 = [_]T{
    .{ .name = "m", .width = 4, .src = .{ .constant = 5 } },
    .{ .name = "na", .width = 11, .src = .{ .field = "na" } },
    .{ .name = "tau_c", .width = 32, .repr = .sign_mag, .scale_log2 = -31, .src = .{ .field = "tau_c" } },
    .{ .name = "reserved_5", .width = 1, .src = .reserved },
    .{ .name = "n4", .width = 5, .src = .{ .field = "n4" } },
    .{ .name = "tau_gps", .width = 22, .repr = .sign_mag, .scale_log2 = -30, .src = .{ .field = "tau_gps" } },
    .{ .name = "ln", .width = 1, .src = .{ .ctx = "ln" } },
};

pub fn scaleMisfit(tau_c: f64, tau_gps: f64) ?[:0]const u8 {
    return field.misfit(TimeScale, &string5, &.{ .na = 1, .n4 = 1, .tau_c = tau_c, .tau_gps = tau_gps });
}

const A = field.Field(Alm);

fn cn(a: *const Alm) i64 {
    return @intFromBool(a.health);
}
fn almSlot(a: *const Alm) i64 {
    return a.sat.prn();
}
fn mn(a: *const Alm) i64 {
    return a.mn orelse 1;
}
fn hna(a: *const Alm) i64 {
    return @mod(@as(i64, a.freq.int()), 32);
}

pub const almanac_even = [_]A{
    .{ .name = "m", .width = 4, .src = .{ .ctx = "m" } },
    .{ .name = "cn", .width = 1, .src = .{ .computed_int = &cn } },
    .{ .name = "mn", .width = 2, .src = .{ .computed_int = &mn } },
    .{ .name = "na", .width = 5, .src = .{ .computed_int = &almSlot } },
    .{ .name = "tau_n", .width = 10, .repr = .sign_mag, .scale_log2 = -18, .src = .{ .field = "tau_n" } },
    .{ .name = "lambda", .width = 21, .repr = .sign_mag, .scale_log2 = -20, .semicircles = true, .periodic = true, .src = .{ .field = "lambda" } },
    .{ .name = "delta_i", .width = 18, .repr = .sign_mag, .scale_log2 = -20, .semicircles = true, .src = .{ .field = "delta_i" } },
    .{ .name = "ecc", .width = 15, .scale_log2 = -20, .src = .{ .field = "ecc" } },
};

pub const almanac_odd = [_]A{
    .{ .name = "m", .width = 4, .src = .{ .ctx = "m" } },
    .{ .name = "w", .width = 16, .repr = .sign_mag, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .field = "w" } },
    .{ .name = "t_lambda_s", .width = 21, .scale_log2 = -5, .src = .{ .field = "t_lambda_s" } },
    .{ .name = "delta_t", .width = 22, .repr = .sign_mag, .scale_log2 = -9, .src = .{ .field = "delta_t" } },
    .{ .name = "delta_t_dot", .width = 7, .repr = .sign_mag, .scale_log2 = -14, .src = .{ .field = "delta_t_dot" } },
    .{ .name = "hna", .width = 5, .src = .{ .computed_int = &hna } },
    .{ .name = "ln", .width = 1, .src = .{ .ctx = "ln" } },
};

const N = field.Field(NoSource);

pub const empty_even = [_]N{
    .{ .name = "m", .width = 4, .src = .{ .ctx = "m" } },
    .{ .name = "cn", .width = 1, .src = .{ .constant = 0 } },
    .{ .name = "mn", .width = 2, .src = .{ .constant = 0 } },
    .{ .name = "na", .width = 5, .src = .{ .ctx = "slot" } },
    .{ .name = "reserved_e", .width = 64, .src = .reserved },
};

pub const filler_odd = [_]N{
    .{ .name = "m", .width = 4, .src = .{ .ctx = "m" } },
    .{ .name = "reserved_fa", .width = 40, .src = .reserved },
    .{ .name = "reserved_fb", .width = 31, .src = .reserved },
    .{ .name = "ln", .width = 1, .src = .{ .ctx = "ln" } },
};

const U = field.Field(String14);
pub const string14 = [_]U{
    .{ .name = "m", .width = 4, .src = .{ .ctx = "m" } },
    .{ .name = "b1", .width = 11, .repr = .sign_mag, .scale_log2 = -10, .src = .{ .field = "b1" } },
    .{ .name = "b2", .width = 10, .repr = .sign_mag, .scale_log2 = -16, .src = .{ .field = "b2" } },
    .{ .name = "kp", .width = 2, .src = .{ .field = "kp" } },
    .{ .name = "reserved_14", .width = 49, .src = .reserved },
};

pub fn misfit(e: *const Eph, leap: civil.Leap) ?[:0]const u8 {
    const moscow_time = e.tb.toGlonass(leap);
    if (moscow_time.sub_ms != 0 or moscow_time.ms_of_day == 0 or
        moscow_time.ms_of_day % records.tb_interval_ms != 0 or
        moscow_time.n4 < 1 or moscow_time.n4 > 31) return "tb";
    if (e.ft) |code| if (code == 15) return "ft";
    inline for (.{ &string1, &string2, &string3, &string4 }) |rows| if (field.misfit(Eph, rows, e)) |name| return name;
    return null;
}

comptime {
    for (.{ string1, string2, string3, string4 }) |layout| std.debug.assert(field.totalWidth(Eph, &layout) == data_bits);
    std.debug.assert(field.totalWidth(TimeScale, &string5) == data_bits);
    std.debug.assert(field.totalWidth(String14, &string14) == data_bits);
    for (.{ almanac_even, almanac_odd }) |layout| std.debug.assert(field.totalWidth(Alm, &layout) == data_bits);
    for (.{ empty_even, filler_odd }) |layout| std.debug.assert(field.totalWidth(NoSource, &layout) == data_bits);
}
