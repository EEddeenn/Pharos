const std = @import("std");
const hermite = @import("domain/trajectory/hermite");

const Ecef = @import("domain/earth/coordinates").Ecef;

pub const Knot = struct {
    t: f64,
    pos: Ecef,
    vel: Ecef,
    acc: Ecef,
};

pub const State = struct { pos: Ecef, vel: Ecef, acc: Ecef, jerk: Ecef };

pub const DomainError = error{ PositionOutOfRange, SpeedOutOfRange, AccelerationOutOfRange, PathOutOfRange };

pub const max_duration_s: f64 = 1e7;

pub const min_radius_m: f64 = 6_350_000;
pub const max_radius_m: f64 = 2e8;
pub const max_speed_mps: f64 = 20_000;
pub const max_acceleration_mps2: f64 = 1_000;

const duration_rounding: f64 = 8.0 * std.math.floatEps(f64);

const hermite_max_h3_minus_s: f64 = 0.1468;
const hermite_max_h4: f64 = 0.1976;
const hermite_max_h2: f64 = 0.0173;
const hermite_max_d3: f64 = 1.875;
const hermite_max_d2: f64 = 0.0678;
const hermite_max_e3: f64 = 5.7736;
const hermite_max_e4: f64 = 3.9403;

/// A completed path with nonempty, ordered knots; construction owns its motion constraints.
pub const Trajectory = struct {
    name: []const u8 = "",
    knots: []const Knot,

    pub fn duration(self: Trajectory) f64 {
        return self.knots[self.knots.len - 1].t;
    }

    pub fn epochs(self: Trajectory) u64 {
        const ms = self.duration() * 1000.0;
        return @intFromFloat(@floor(ms * (1.0 + duration_rounding)));
    }

    pub fn moves(self: Trajectory, span_s: f64) bool {
        const first = self.knots[0].pos;
        const rest: Ecef = .{ .x = 0, .y = 0, .z = 0 };
        for (self.knots) |k| {
            if (!std.meta.eql(k.pos, first) or !std.meta.eql(k.vel, rest) or !std.meta.eql(k.acc, rest)) return true;
            if (k.t >= span_s) break;
        }
        return false;
    }

    pub fn at(self: Trajectory, t: f64) State {
        const ks = self.knots;
        const n = std.sort.partitionPoint(Knot, ks, t, atOrBefore);
        if (n == 0) return extrapolate(ks[0], t);
        if (n == ks.len) return extrapolate(ks[ks.len - 1], t);
        return between(ks[n - 1], ks[n], t);
    }
};

pub fn reason(e: DomainError) []const u8 {
    const radii = std.fmt.comptimePrint("from {d} to {d} m", .{ min_radius_m, max_radius_m });
    return switch (e) {
        error.PositionOutOfRange => "a position's distance from the geocentre must be " ++ radii,
        error.SpeedOutOfRange => "a speed exceeds 20000 m/s",
        error.AccelerationOutOfRange => "an acceleration exceeds 1000 m/s^2",
        error.PathOutOfRange => std.fmt.comptimePrint("the path from the knot before may leave a distance from the geocentre {s}, a speed of at most {d} m/s or an acceleration of at most {d} m/s^2", .{ radii, max_speed_mps, max_acceleration_mps2 }),
    };
}

pub fn positionInRange(pos: Ecef) bool {
    const r = pos.norm();
    return r >= min_radius_m and r <= max_radius_m;
}

/// The bound of the receiver's domain a state breaks, if any.
pub fn outside(pos: Ecef, vel: Ecef, acc: Ecef) ?DomainError {
    if (!positionInRange(pos)) return error.PositionOutOfRange;
    if (!(vel.norm() <= max_speed_mps)) return error.SpeedOutOfRange;
    if (!(acc.norm() <= max_acceleration_mps2)) return error.AccelerationOutOfRange;
    return null;
}

/// Whether the quintic between two knots of a positive span keeps to the receiver's domain, by a bound of its
/// distance from the geocentre, its speed and its acceleration from the knots' states.
pub fn pathInRange(k0: Knot, k1: Knot) bool {
    const h = k1.t - k0.t;
    const dp = k1.pos.sub(k0.pos);
    const drift = dp.sub(k0.vel.scale(h)).norm();
    const dv = k1.vel.sub(k0.vel).norm();
    const acc = k0.acc.norm() + k1.acc.norm();
    const off_chord = hermite_max_h3_minus_s * drift + hermite_max_h4 * h * dv + hermite_max_h2 * h * h * acc;
    const speed = k0.vel.norm() + hermite_max_d3 * drift / h + dv + hermite_max_d2 * h * acc;
    const dv_a = k1.vel.sub(k0.vel).sub(k0.acc.scale(h)).norm();
    const drift_a = dp.sub(k0.vel.scale(h)).sub(k0.acc.scale(h * h / 2)).norm();
    const acceleration = @min(
        hermite_max_e4 * dv / h + hermite_max_e3 * drift / (h * h) + acc,
        k0.acc.norm() + hermite_max_e4 * dv_a / h + hermite_max_e3 * drift_a / (h * h) + k1.acc.sub(k0.acc).norm(),
    );
    const len2 = dp.dot(dp);
    const s = if (len2 > 0) std.math.clamp(-k0.pos.dot(dp) / len2, 0, 1) else 0;
    const nearest = k0.pos.add(dp.scale(s)).norm();
    const farthest = @max(k0.pos.norm(), k1.pos.norm());
    return nearest - off_chord >= min_radius_m and farthest + off_chord <= max_radius_m and
        speed <= max_speed_mps and acceleration <= max_acceleration_mps2;
}

/// The quintics of the stored piece from k0 to k1, an axis each, by the fraction of its time.
pub fn coefficients(k0: Knot, k1: Knot) [3]hermite.Scalar.Quintic {
    const h = k1.t - k0.t;
    const p0 = k0.pos.toArray();
    const v0 = k0.vel.toArray();
    const a0 = k0.acc.toArray();
    const p1 = k1.pos.toArray();
    const v1 = k1.vel.toArray();
    const a1 = k1.acc.toArray();
    var out: [3]hermite.Scalar.Quintic = undefined;
    for (&out, 0..) |*c, axis| c.* = hermite.Scalar.quintic(p0[axis], v0[axis], a0[axis], p1[axis], v1[axis], a1[axis], h);
    return out;
}

pub fn between(k0: Knot, k1: Knot, t: f64) State {
    const h = k1.t - k0.t;
    const u = (t - k0.t) / h;
    var position: [3]f64 = undefined;
    var velocity: [3]f64 = undefined;
    var acceleration: [3]f64 = undefined;
    var jerk: [3]f64 = undefined;
    for (coefficients(k0, k1), 0..) |c, axis| {
        const value = hermite.Scalar.motion(c, h, u);
        position[axis] = value.position;
        velocity[axis] = value.velocity;
        acceleration[axis] = value.acceleration;
        jerk[axis] = value.jerk;
    }
    return .{
        .pos = .fromArray(position),
        .vel = .fromArray(velocity),
        .acc = .fromArray(acceleration),
        .jerk = .fromArray(jerk),
    };
}

fn atOrBefore(t: f64, k: Knot) bool {
    return k.t <= t;
}

fn extrapolate(k: Knot, t: f64) State {
    const dt = t - k.t;
    return .{
        .pos = k.pos.add(k.vel.scale(dt)).add(k.acc.scale(dt * dt / 2)),
        .vel = k.vel.add(k.acc.scale(dt)),
        .acc = k.acc,
        .jerk = .{ .x = 0, .y = 0, .z = 0 },
    };
}
