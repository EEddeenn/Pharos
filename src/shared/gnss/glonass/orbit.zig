const std = @import("std");
const constants = @import("constants.zig");
const elements = @import("../../core.zig").elements;
const GpsTime = @import("../../core.zig").time.GpsTime;
const Ecef = @import("../../core.zig").coord.Ecef;
const records = @import("records.zig");

const step_tolerance_s = 1e-9;

const kept_steps = 64;

pub const State = struct { pos: Ecef, vel: Ecef };

const min_period_s: f64 = 39_600;
const max_period_s: f64 = 46_800;
const max_ecc: f64 = 0.03;
pub const mean_inclination_deg = 63.0;
pub const mean_inclination: f64 = mean_inclination_deg * std.math.pi / 180.0;
pub const mean_draconic_period_s = 43_200.0;
const max_delta_i: f64 = 0.067 * std.math.pi;

pub fn misfit(g: *const records.GlonassEphemeris) ?[:0]const u8 {
    const pos: Ecef = .fromArray(g.pos);
    const v = elements.inertial(.fromArray(g.vel), pos, constants.pz90_omegdote);
    const el = elements.fromState(pos, v, constants.pz90_gm) orelse return "orbit period";
    const period = 2.0 * std.math.pi * @sqrt(el.a * el.a * el.a / constants.pz90_gm);
    if (!(period >= min_period_s and period <= max_period_s)) return "orbit period";
    if (!(el.ecc <= max_ecc)) return "eccentricity";
    if (!(@abs(el.i - mean_inclination) <= max_delta_i)) return "inclination";
    return null;
}

pub const Orbit = struct {
    tb: GpsTime,
    x0: [6]f64,
    acc: [3]f64,
    kept: Kept = .{},

    const Kept = struct {
        side: i2 = 0,
        last: usize = 0,
        count: usize = 0,
        x: [kept_steps][6]f64 = undefined,
    };

    pub fn fromEphemeris(g: *const records.GlonassEphemeris) Orbit {
        std.debug.assert(misfit(g) == null);
        return fromState(g.tb, .{ .pos = .fromArray(g.pos), .vel = .fromArray(g.vel) }, g.acc);
    }

    pub fn fromState(t: GpsTime, s: State, acc: [3]f64) Orbit {
        return .{ .tb = t, .x0 = .{ s.pos.x, s.pos.y, s.pos.z, s.vel.x, s.vel.y, s.vel.z }, .acc = acc };
    }

    pub fn advance(self: *Orbit, t: GpsTime) State {
        const dt = t.secondsSince(self.tb);
        const whole: i64 = @intFromFloat(@trunc(dt));
        var x = self.stepped(whole);
        const tail = dt - @as(f64, @floatFromInt(whole));
        if (@abs(tail) > step_tolerance_s) x = rk4(x, self.acc, tail);
        return ecefOf(x);
    }

    fn stepped(self: *Orbit, whole: i64) [6]f64 {
        if (whole == 0) return self.x0;
        const side: i2 = if (whole > 0) 1 else -1;
        const target_step: usize = @intCast(@abs(whole));
        const kept = &self.kept;
        const same_direction = kept.side == side;
        if (same_direction and target_step <= kept.last and target_step + kept.count > kept.last) return kept.x[target_step % kept_steps];

        const start_step: usize = if (same_direction and target_step > kept.last) kept.last else 0;
        var x = if (start_step > 0) kept.x[start_step % kept_steps] else self.x0;
        const h: f64 = @floatFromInt(side);
        var i = start_step;
        while (i < target_step) {
            x = rk4(x, self.acc, h);
            i += 1;
            kept.x[i % kept_steps] = x;
        }

        kept.count = @min(kept_steps, (if (start_step > 0) kept.count else 0) + target_step - start_step);
        kept.side = side;
        kept.last = target_step;
        return x;
    }

    pub fn state(self: *const Orbit, t: GpsTime) State {
        var x = self.x0;
        var remaining = t.secondsSince(self.tb);
        while (@abs(remaining) > step_tolerance_s) {
            const h = std.math.copysign(@min(@abs(remaining), 1.0), remaining);
            x = rk4(x, self.acc, h);
            remaining -= h;
        }
        return ecefOf(x);
    }
};

fn ecefOf(x: [6]f64) State {
    return .{ .pos = .fromArray(x[0..3].*), .vel = .fromArray(x[3..6].*) };
}

fn acceleration(x: [6]f64, acc: [3]f64) [3]f64 {
    const c = constants.orbit;
    const r2 = x[0] * x[0] + x[1] * x[1] + x[2] * x[2];
    const r3 = r2 * @sqrt(r2);
    const omega2 = c.omega_e * c.omega_e;
    const a = 1.5 * constants.pz90_j02 * c.mu * constants.pz90_ae * constants.pz90_ae / r2 / r3;
    const b = 5.0 * x[2] * x[2] / r2;
    const k = -c.mu / r3 - a * (1.0 - b);
    return .{
        (k + omega2) * x[0] + 2.0 * c.omega_e * x[4] + acc[0],
        (k + omega2) * x[1] - 2.0 * c.omega_e * x[3] + acc[1],
        (k - 2.0 * a) * x[2] + acc[2],
    };
}

fn deriv(x: [6]f64, acc: [3]f64) [6]f64 {
    const a = acceleration(x, acc);
    return .{ x[3], x[4], x[5], a[0], a[1], a[2] };
}

fn rk4(x: [6]f64, acc: [3]f64, h: f64) [6]f64 {
    const k1 = deriv(x, acc);
    const k2 = deriv(axpy(x, k1, h / 2), acc);
    const k3 = deriv(axpy(x, k2, h / 2), acc);
    const k4 = deriv(axpy(x, k3, h), acc);
    var out: [6]f64 = undefined;
    for (0..6) |i| out[i] = x[i] + (k1[i] + 2 * k2[i] + 2 * k3[i] + k4[i]) * h / 6;
    return out;
}

fn axpy(x: [6]f64, k: [6]f64, h: f64) [6]f64 {
    var out: [6]f64 = undefined;
    for (0..6) |i| out[i] = x[i] + k[i] * h;
    return out;
}
