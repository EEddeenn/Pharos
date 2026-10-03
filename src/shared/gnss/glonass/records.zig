const types = @import("../../core.zig").types;
const time = @import("../../core.zig").time;
const civil = @import("../../core.zig").civil;
const ClockPoly = @import("../../core.zig").clock.Poly;

pub const GlonassEphemeris = struct {
    sat: types.SatId,
    freq: types.FreqId,
    tb: time.GpsTime,
    pos: [3]f64,
    vel: [3]f64,
    acc: [3]f64,
    gamma_n: f64,
    tau_n: f64,
    delta_tau_n: ?f64,
    health: bool,
    almanac_health: ?bool,
    ft: ?u4,
    en: u5,
    p: ?u2,
    p1: u2,
    p4: ?bool,
    m: ?u2,

    pub fn clock(self: *const GlonassEphemeris) ClockPoly {
        return .{ .toc = self.tb, .af0 = -self.tau_n, .af1 = self.gamma_n, .af2 = 0 };
    }
};

pub const tb_interval_ms = 900_000;

const update_interval_ms = 1_800_000;

pub fn adoption(g: *const GlonassEphemeris, leap: civil.Leap) time.GpsTime {
    var moscow = g.tb.toGlonass(leap);
    moscow.ms_of_day -= update_interval_ms / 2;
    return time.GpsTime.fromGlonass(leap, moscow);
}

pub const GlonassAlmanac = struct {
    sat: types.SatId,
    freq: types.FreqId,
    health: bool,
    mn: ?u2,
    n4: u5,
    na: u16,
    t_lambda_s: f64,
    lambda: f64,
    delta_i: f64,
    ecc: f64,
    w: f64,
    delta_t: f64,
    delta_t_dot: f64,
    tau_n: f64,
};
