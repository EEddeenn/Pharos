const std = @import("std");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const elements = @import("domain/navigation/orbit/elements");
const constants = @import("domain/navigation/orbit/constants/glonass");
const orbit = @import("domain/navigation/orbit/glonass");
const glonass_records = @import("domain/navigation/records/glonass");
const angles = @import("base/math/angles");

const Orbit = orbit.Orbit;

const GpsTime = time.GpsTime;

pub const max_span_s: f64 = 86_400;
const node_tolerance_m = 1e-3;

const lunisolar_span_ms: i64 = 900_000;

pub const Path = struct {
    near: Orbit,
    before: Orbit,
    after: Orbit,

    pub fn init(eph: *const glonass_records.GlonassEphemeris) Path {
        const near = Orbit.fromEphemeris(eph);
        const t0 = eph.tb.addMs(-lunisolar_span_ms);
        const t1 = eph.tb.addMs(lunisolar_span_ms);
        return .{
            .near = near,
            .before = Orbit.fromState(t0, near.state(t0), @splat(0)),
            .after = Orbit.fromState(t1, near.state(t1), @splat(0)),
        };
    }

    fn state(self: *Path, t: GpsTime) orbit.State {
        if (t.lessThan(self.before.tb)) return self.before.advance(t);
        if (self.after.tb.lessThan(t)) return self.after.advance(t);
        return self.near.advance(t);
    }
};

pub fn nodeEstimate(path: *Path, t: GpsTime) ?GpsTime {
    const s = path.state(t);
    const v = elements.inertial(s.vel, s.pos, constants.pz90_omegdote);
    const r = s.pos.norm();
    const inverse_a = 2.0 / r - v.dot(v) / constants.pz90_gm;
    if (!(inverse_a > 0 and std.math.isFinite(inverse_a))) return null;
    const a = 1.0 / inverse_a;
    const n = @sqrt(constants.pz90_gm / (a * a * a));
    const phase = std.math.atan2(s.pos.z, v.z / n);
    return t.addSeconds(-phase / n);
}

pub fn fromEphemeris(eph: *const glonass_records.GlonassEphemeris, n4: u5, na: u16, leap: civil.Leap) ?glonass_records.GlonassAlmanac {
    var path = Path.init(eph);
    const day_start = GpsTime.fromGlonass(leap, .{ .n4 = n4, .nt = na, .ms_of_day = 0, .sub_ms = 0 });
    var guess = nodeEstimate(&path, eph.tb) orelse return null;
    const s0 = path.state(guess);
    const v0 = elements.inertial(s0.vel, s0.pos, constants.pz90_omegdote);
    const r0 = s0.pos.norm();
    const a0 = 1.0 / (2.0 / r0 - v0.dot(v0) / constants.pz90_gm);
    if (a0 <= 0) return null;
    const period = angles.two_pi * @sqrt(a0 * a0 * a0 / constants.pz90_gm);
    const offset = guess.secondsSince(day_start);
    guess = guess.addSeconds(-@floor(offset / period) * period);
    if (!(@abs(guess.secondsSince(eph.tb)) <= max_span_s)) return null;
    const node = ascendingNode(&path, guess) orelse return null;
    const s = path.state(node);
    const v = elements.inertial(s.vel, s.pos, constants.pz90_omegdote);
    const el = elements.fromState(s.pos, v, constants.pz90_gm) orelse return null;
    const j2 = constants.pz90_c20;
    const t_kepler = angles.two_pi * @sqrt(el.a * el.a * el.a / constants.pz90_gm);
    const w = elements.normAngle(-el.true_anomaly);
    const t_dr = t_kepler * (1.0 - 1.5 * j2 * constants.pz90_ae2 / (el.p * el.p) * draconiticFactor(el.i, el.ecc, w));
    return .{
        .sat = eph.sat,
        .freq = eph.freq,
        .health = eph.almanac_health orelse eph.health,
        .mn = eph.m,
        .n4 = n4,
        .na = na,
        .t_lambda_s = timeOfDay(node, day_start, leap),
        .lambda = std.math.atan2(s.pos.y, s.pos.x),
        .delta_i = el.i - orbit.mean_inclination,
        .ecc = el.ecc,
        .w = w,
        .delta_t = t_dr - orbit.mean_draconic_period_s,
        .delta_t_dot = 0,
        .tau_n = eph.tau_n,
    };
}

fn draconiticFactor(i: f64, ecc: f64, w: f64) f64 {
    const s2 = @sin(i) * @sin(i);
    const q = 1.0 + ecc * @cos(w);
    const one_e2 = 1.0 - ecc * ecc;
    return (2.0 - 2.5 * s2) * one_e2 * @sqrt(one_e2) / (q * q) + q * q * q / one_e2;
}

fn ascendingNode(path: *Path, guess: GpsTime) ?GpsTime {
    var t = guess;
    for (0..3) |_| {
        var iter: usize = 0;
        var s = path.state(t);
        const r0 = s.pos.norm();
        const quarter = 0.5 * std.math.pi * @sqrt(r0 * r0 * r0 / constants.pz90_gm);
        while (iter < 8 and @abs(s.pos.z) > node_tolerance_m) : (iter += 1) {
            const step = -s.pos.z / s.vel.z;
            if (!(@abs(step) <= quarter)) return null;
            t = t.addSeconds(step);
            s = path.state(t);
        }
        if (@abs(s.pos.z) > node_tolerance_m) return null;
        if (s.vel.z > 0) return t;
        const r = s.pos.norm();
        const half = std.math.pi * @sqrt(r * r * r / constants.pz90_gm);
        t = t.addSeconds(half);
    }
    return null;
}

fn timeOfDay(node: GpsTime, day_start: GpsTime, leap: civil.Leap) f64 {
    return (@as(f64, @floatFromInt(node.baseMs(.glo, leap) - day_start.baseMs(.glo, leap))) + node.sub_ms) / 1000.0;
}
