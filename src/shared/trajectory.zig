const std = @import("std");
const core = @import("core.zig");
const Ecef = core.coord.Ecef;

pub const hermite = @import("trajectory/hermite.zig");

pub const pht = @import("trajectory/pht.zig");
pub const kml = @import("trajectory/kml.zig");
pub const positions = @import("trajectory/positions.zig");

pub const Knot = struct {
    t: f64,
    pos: Ecef,
    vel: Ecef,
    acc: Ecef,
};

pub const State = struct { pos: Ecef, vel: Ecef, acc: Ecef, jerk: Ecef };

pub const Error = error{ NoKnots, FirstKnotNotAtZero, NotFinite, TimeGoesBack, TimeGivenThrice, PositionJump, TooLong, PositionOutOfRange, SpeedOutOfRange, AccelerationOutOfRange, PathOutOfRange };

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

pub fn reason(e: Error) []const u8 {
    return switch (e) {
        error.NoKnots => "no knot",
        error.FirstKnotNotAtZero => "the first knot is not at 0 s",
        error.NotFinite => "a value is not finite",
        error.TimeGoesBack => "a time goes back",
        error.TimeGivenThrice => "three knots share a time",
        error.PositionJump => "two knots at one time are at different positions",
        error.TooLong => "a time exceeds 10^7 s",
        error.PositionOutOfRange => "a position lies outside 6350 km to 200000 km from the geocentre",
        error.SpeedOutOfRange => "a speed exceeds 20000 m/s",
        error.AccelerationOutOfRange => "an acceleration exceeds 1000 m/s^2",
        error.PathOutOfRange => "the path from the previous knot may leave the position, speed or acceleration range",
    };
}

pub fn positionInRange(pos: Ecef) bool {
    const r = pos.norm();
    return r >= min_radius_m and r <= max_radius_m;
}

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

    pub const Invalid = struct {
        reason: Error,
        location: ?struct { knot: usize, t: f64 } = null,

        pub fn format(self: Invalid, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.location) |location| try w.print("knot {d} at {d} s: ", .{ location.knot + 1, location.t });
            try w.print("{s} ({s})", .{ @errorName(self.reason), reason(self.reason) });
        }
    };

    pub fn invalid(self: Trajectory) ?Invalid {
        if (self.knots.len == 0) return .{ .reason = error.NoKnots };
        for (self.knots, 0..) |k, i| {
            checkKnot(self.knots, i) catch |e| return .{ .reason = e, .location = .{ .knot = i, .t = k.t } };
        }
        return null;
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

fn atOrBefore(t: f64, k: Knot) bool {
    return k.t <= t;
}

pub fn checkKnot(knots: []const Knot, i: usize) Error!void {
    const k = knots[i];
    for ([_]Ecef{ k.pos, k.vel, k.acc }) |v| {
        if (!std.math.isFinite(v.x) or !std.math.isFinite(v.y) or !std.math.isFinite(v.z)) return error.NotFinite;
    }
    if (!std.math.isFinite(k.t)) return error.NotFinite;
    if (!positionInRange(k.pos)) return error.PositionOutOfRange;
    if (!(k.vel.norm() <= max_speed_mps)) return error.SpeedOutOfRange;
    if (!(k.acc.norm() <= max_acceleration_mps2)) return error.AccelerationOutOfRange;
    if (i == 0) {
        if (k.t != 0) return error.FirstKnotNotAtZero;
        return;
    }
    const prev = knots[i - 1];
    if (k.t < prev.t) return error.TimeGoesBack;
    if (k.t > max_duration_s) return error.TooLong;
    if (k.t == prev.t) {
        if (i >= 2 and knots[i - 2].t == k.t) return error.TimeGivenThrice;
        if (k.pos.x != prev.pos.x or k.pos.y != prev.pos.y or k.pos.z != prev.pos.z) return error.PositionJump;
        return;
    }
    if (!pathInRange(prev, k)) return error.PathOutOfRange;
}

fn pathInRange(k0: Knot, k1: Knot) bool {
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

fn extrapolate(k: Knot, t: f64) State {
    const dt = t - k.t;
    return .{
        .pos = k.pos.add(k.vel.scale(dt)).add(k.acc.scale(dt * dt / 2)),
        .vel = k.vel.add(k.acc.scale(dt)),
        .acc = k.acc,
        .jerk = .{ .x = 0, .y = 0, .z = 0 },
    };
}

pub fn between(k0: Knot, k1: Knot, t: f64) State {
    const h = k1.t - k0.t;
    const u = (t - k0.t) / h;
    const left_p = k0.pos.toArray();
    const left_v = k0.vel.toArray();
    const left_a = k0.acc.toArray();
    const right_p = k1.pos.toArray();
    const right_v = k1.vel.toArray();
    const right_a = k1.acc.toArray();
    var position: [3]f64 = undefined;
    var velocity: [3]f64 = undefined;
    var acceleration: [3]f64 = undefined;
    var jerk: [3]f64 = undefined;
    for (0..3) |axis| {
        const coefficients = hermite.Scalar.quintic(left_p[axis], left_v[axis], left_a[axis], right_p[axis], right_v[axis], right_a[axis], h);
        const value = hermite.Scalar.motion(coefficients, h, u);
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
