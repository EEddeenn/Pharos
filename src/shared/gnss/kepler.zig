const std = @import("std");
const constants = @import("../core.zig").constants;
const system_constants = @import("constants.zig");
const time = @import("../core.zig").time;
const GpsTime = time.GpsTime;
const Ecef = @import("../core.zig").coord.Ecef;
const records = @import("records.zig");
const Parameters = @import("kepler_parameters.zig").Parameters;
const bds = @import("bds/records.zig");

pub const State = struct {
    pos: Ecef,
    vel: Ecef,
    rel_s: f64,
};

pub const window_s: f64 = 7200;

pub fn misfit(eph: *const records.KeplerEphemeris) ?[:0]const u8 {
    return eph.parameters().misfit();
}

pub const Orbit = struct {
    toe: GpsTime,
    toe_sow: f64,
    mu: f64,
    omega_e: f64,
    geo: bool,
    a: f64,
    a_dot: f64,
    n: f64,
    delta_n_dot: f64,
    e: f64,
    root_1me2: f64,
    m0: f64,
    w: f64,
    omega0: f64,
    omega_dot: f64,
    i0: f64,
    idot: f64,
    cuc: f64,
    cus: f64,
    crc: f64,
    crs: f64,
    cic: f64,
    cis: f64,

    pub fn fromEphemeris(eph: *const records.KeplerEphemeris) Orbit {
        return fromParameters(&eph.parameters());
    }

    pub fn fromParameters(eph: *const Parameters) Orbit {
        std.debug.assert(eph.misfit() == null);
        const a = eph.sqrt_a * eph.sqrt_a;
        const system = eph.system();
        const c = system_constants.get(system);
        return .{
            .toe = eph.toe,
            .toe_sow = eph.toe.inScale(eph.weekScale()).asF64Seconds(),
            .mu = c.mu,
            .omega_e = c.omega_e,
            .geo = system == .bds and bds.isGeo(eph.sat.prn()),
            .a = a,
            .a_dot = eph.a_dot,
            .n = @sqrt(c.mu / (a * a * a)) + eph.delta_n,
            .delta_n_dot = eph.delta_n_dot,
            .e = eph.ecc,
            .root_1me2 = @sqrt(1.0 - eph.ecc * eph.ecc),
            .m0 = eph.m0,
            .w = eph.w,
            .omega0 = eph.omega0,
            .omega_dot = eph.omega_dot,
            .i0 = eph.i0,
            .idot = eph.idot,
            .cuc = eph.cuc,
            .cus = eph.cus,
            .crc = eph.crc,
            .crs = eph.crs,
            .cic = eph.cic,
            .cis = eph.cis,
        };
    }

    fn eccentricAnomaly(self: *const Orbit, m: f64) f64 {
        var ek = m;
        for (0..5) |_| ek -= (ek - self.e * @sin(ek) - m) / (1.0 - self.e * @cos(ek));
        return ek;
    }

    pub fn state(self: *const Orbit, t: GpsTime) State {
        const tk = t.secondsSince(self.toe);
        const alpha = self.delta_n_dot * tk;
        const mk = self.m0 + (self.n + alpha / 2.0) * tk;
        const ek = self.eccentricAnomaly(mk);
        const sin_e = @sin(ek);
        const cos_e = @cos(ek);
        const one_me_cos = 1.0 - self.e * cos_e;
        const nu = std.math.atan2(self.root_1me2 * sin_e, cos_e - self.e);
        const phi = nu + self.w;

        const sin2 = @sin(2.0 * phi);
        const cos2 = @cos(2.0 * phi);
        const duk = self.cuc * cos2 + self.cus * sin2;
        const drk = self.crc * cos2 + self.crs * sin2;
        const dik = self.cic * cos2 + self.cis * sin2;
        const axis = self.a + self.a_dot * tk;
        const uk = phi + duk;
        const rk = axis * one_me_cos + drk;
        const ik = self.i0 + self.idot * tk + dik;

        const ek_dot = (self.n + alpha) / one_me_cos;
        const nu_dot = ek_dot * self.root_1me2 / one_me_cos;
        const phi_dot2 = 2.0 * nu_dot;
        const rk_dot = axis * self.e * sin_e * ek_dot + self.a_dot * one_me_cos + (self.crs * cos2 - self.crc * sin2) * phi_dot2;
        const uk_dot = nu_dot + (self.cus * cos2 - self.cuc * sin2) * phi_dot2;
        const ik_dot = self.idot + (self.cis * cos2 - self.cic * sin2) * phi_dot2;

        const su = @sin(uk);
        const cu = @cos(uk);
        const xp = rk * cu;
        const yp = rk * su;
        const xp_dot = rk_dot * cu - yp * uk_dot;
        const yp_dot = rk_dot * su + xp * uk_dot;

        const omega_rate = if (self.geo) self.omega_dot else self.omega_dot - self.omega_e;
        const omega = self.omega0 - self.omega_e * self.toe_sow + omega_rate * tk;
        const so = @sin(omega);
        const co = @cos(omega);
        const si = @sin(ik);
        const ci = @cos(ik);
        var x = xp * co - yp * ci * so;
        var y = xp * so + yp * ci * co;
        var z = yp * si;
        const pd = yp_dot * ci - z * ik_dot;
        var vx = xp_dot * co - pd * so - y * omega_rate;
        var vy = xp_dot * so + pd * co + x * omega_rate;
        var vz = yp_dot * si + yp * ci * ik_dot;

        if (self.geo) {
            const cos5 = 0.99619469809174553;
            const sin5 = 0.087155742747658173559;
            const yr = y * cos5 - z * sin5;
            z = z * cos5 + y * sin5;
            const vyr = vy * cos5 - vz * sin5;
            vz = vz * cos5 + vy * sin5;
            const theta = self.omega_e * tk;
            const st = @sin(theta);
            const ct = @cos(theta);
            y = yr * ct - x * st;
            x = x * ct + yr * st;
            vy = vyr * ct - vx * st;
            vx = vx * ct + vyr * st;
            vx += y * self.omega_e;
            vy -= x * self.omega_e;
        }

        return .{
            .pos = .{ .x = x, .y = y, .z = z },
            .vel = .{ .x = vx, .y = vy, .z = vz },
            .rel_s = -2.0 * @sqrt(self.mu * axis) * self.e * sin_e / (constants.light_speed * constants.light_speed),
        };
    }
};
