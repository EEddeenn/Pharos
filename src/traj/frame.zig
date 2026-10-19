//! The local frame of a point in motion, and the motion read in that frame, each with its first and second rate in
//! time: what inspection reads off a state, and what a through's heights follow.
const std = @import("std");
const core = @import("shared").core;
const constants = core.constants;
const shared_trajectory = @import("shared").trajectory;
const Altitude = @import("plan/model.zig").Altitude;

/// A value with its first and second derivatives in time.
pub const Jet = struct {
    value: f64,
    first: f64 = 0,
    second: f64 = 0,

    /// The arithmetic the shared geoid evaluates its height in.
    pub const Arithmetic = struct {
        pub const add = Jet.add;
        pub const sub = Jet.sub;
        pub const mul = Jet.mul;
        pub const scale = Jet.scale;
        pub const sqrt = Jet.sqrt;
        pub const atan2 = Jet.atan2;

        pub fn constant(number: f64) Jet {
            return .{ .value = number };
        }

        pub fn value(number: Jet) f64 {
            return number.value;
        }

        pub fn failed() Jet {
            const nan = std.math.nan(f64);
            return .{ .value = nan, .first = nan, .second = nan };
        }
    };

    pub fn add(a: Jet, b: Jet) Jet {
        return .{ .value = a.value + b.value, .first = a.first + b.first, .second = a.second + b.second };
    }

    pub fn sub(a: Jet, b: Jet) Jet {
        return .{ .value = a.value - b.value, .first = a.first - b.first, .second = a.second - b.second };
    }

    pub fn scale(a: Jet, k: f64) Jet {
        return .{ .value = a.value * k, .first = a.first * k, .second = a.second * k };
    }

    pub fn mul(a: Jet, b: Jet) Jet {
        return .{
            .value = a.value * b.value,
            .first = a.first * b.value + a.value * b.first,
            .second = a.second * b.value + 2 * a.first * b.first + a.value * b.second,
        };
    }

    pub fn div(a: Jet, b: Jet) Jet {
        const value = a.value / b.value;
        const first = (a.first - value * b.first) / b.value;
        return .{ .value = value, .first = first, .second = (a.second - 2 * first * b.first - value * b.second) / b.value };
    }

    pub fn sqrt(a: Jet) Jet {
        const value = @sqrt(a.value);
        const first = a.first / value * 0.5;
        return .{ .value = value, .first = first, .second = (a.second * 0.5 - first * first) / value };
    }

    pub fn atan2(y: Jet, x: Jet) Jet {
        // Scaled first, so that the squares of a small velocity neither underflow nor lose digits.
        const by = 1 / @max(@abs(x.value), @abs(y.value));
        const xs = x.scale(by);
        const ys = y.scale(by);
        const squared = xs.value * xs.value + ys.value * ys.value;
        const first = (xs.value * ys.first - ys.value * xs.first) / squared;
        const radial = xs.value * xs.first + ys.value * ys.first;
        return .{
            .value = std.math.atan2(y.value, x.value),
            .first = first,
            .second = (xs.value * ys.second - ys.value * xs.second - 2 * radial * first) / squared,
        };
    }
};

pub const Vector = [3]Jet;

/// A position, velocity and acceleration as the jet of the position.
pub fn positionJet(pos: core.coord.Ecef, vel: core.coord.Ecef, acc: core.coord.Ecef) Vector {
    return .{
        .{ .value = pos.x, .first = vel.x, .second = acc.x },
        .{ .value = pos.y, .first = vel.y, .second = acc.y },
        .{ .value = pos.z, .first = vel.z, .second = acc.z },
    };
}

pub fn dot(a: Vector, b: Vector) Jet {
    return a[0].mul(b[0]).add(a[1].mul(b[1])).add(a[2].mul(b[2]));
}

pub fn unit(v: Vector) Vector {
    const magnitude = dot(v, v).sqrt();
    return .{ v[0].div(magnitude), v[1].div(magnitude), v[2].div(magnitude) };
}

fn cross(a: Vector, b: Vector) Vector {
    return .{
        a[1].mul(b[2]).sub(a[2].mul(b[1])),
        a[2].mul(b[0]).sub(a[0].mul(b[2])),
        a[0].mul(b[1]).sub(a[1].mul(b[0])),
    };
}

/// The WGS84 frame (east, north and the ellipsoid's normal) where a point is, and its ellipsoidal height.
pub const Frame = struct {
    east: Vector,
    north: Vector,
    up: Vector,
    height: Jet,

    pub fn at(position: Vector) Frame {
        const primal: core.coord.Ecef = .{ .x = position[0].value, .y = position[1].value, .z = position[2].value };
        const a = constants.wgs_axis_a;
        const beta2 = 1 - constants.wgs_e1_sqr;
        // The point's foot on the ellipsoid, as a multiple along the normal: three Newton steps from the
        // geodetic height, each of the jets.
        const initial = core.coord.ecefToLla(primal);
        const sine = @sin(initial.lat_rad);
        var multiplier: Jet = .{ .value = initial.height_m / a * @sqrt(1 - constants.wgs_e1_sqr * sine * sine) };
        var r: Vector = undefined;
        for (&r, position) |*out, value| out.* = value.scale(1 / a);
        const horizontal = r[0].mul(r[0]).add(r[1].mul(r[1]));
        const vertical = r[2].mul(r[2]).scale(beta2);
        const one: Jet = .{ .value = 1 };
        const flattened: Jet = .{ .value = beta2 };
        for (0..3) |_| {
            const equatorial = multiplier.add(one);
            const polar = multiplier.add(flattened);
            const equatorial2 = equatorial.mul(equatorial);
            const polar2 = polar.mul(polar);
            const residual = horizontal.div(equatorial2).add(vertical.div(polar2)).sub(one);
            const slope = horizontal.div(equatorial2.mul(equatorial)).add(vertical.div(polar2.mul(polar))).scale(-2);
            multiplier = multiplier.sub(residual.div(slope));
        }
        const equatorial = multiplier.add(one);
        const polar = multiplier.add(flattened);
        const up = unit(.{ r[0].div(equatorial), r[1].div(equatorial), r[2].div(polar) });
        const support = up[0].mul(up[0]).add(up[1].mul(up[1])).add(up[2].mul(up[2]).scale(beta2)).sqrt();
        const height = dot(r, up).sub(support).scale(a);
        // On the axis the east of the longitude is undefined: the one of the meridian the normal leans to.
        const east = if (primal.x * primal.x + primal.y * primal.y <= 1e-12)
            unit(.{ up[0].mul(up[1]).scale(-1), one.sub(up[1].mul(up[1])), up[2].mul(up[1]).scale(-1) })
        else
            unit(.{ up[1].scale(-1), up[0], .{ .value = 0 } });
        return .{ .east = east, .north = cross(up, east), .up = up, .height = height };
    }
};

/// A course in [0, 360) degrees clockwise from north.
pub fn courseDeg(rad: f64) f64 {
    const deg = constants.rad2deg(rad);
    const wrapped = if (deg < 0) deg + 360 else deg;
    // A course just under 0 rounds to 360; and -0 is 0.
    return if (wrapped >= 360) 0 else wrapped + 0;
}

/// The horizontal speed below which a velocity has no direction of travel: under a millimetre a second the direction
/// is the rounding of the velocity, not a direction.
pub const moving_mps = 1e-3;

/// A state of the path read in its local frame, as it moves at its height: the acceleration along the horizontal
/// direction of travel ĥ and across it (along ĥ × up, + to the right), the jerk along it, the turn rate as the
/// lateral acceleration over the horizontal speed; the altitude in the plan's reference with its first and second
/// rates. The quantities of the direction of travel are null where the horizontal speed is below `moving_mps`:
/// there they have no value.
pub const Reading = struct {
    altitude_m: f64,
    climb_mps: f64,
    vertical_acceleration_mps2: f64,
    speed_mps: f64,
    horizontal_speed_mps: f64,
    acceleration_mps2: f64,
    jerk_mps3: f64,
    course_deg: ?f64,
    turn_rate_degps: ?f64,
    forward_acceleration_mps2: ?f64,
    forward_jerk_mps3: ?f64,
    lateral_acceleration_mps2: ?f64,

    /// Over EGM96, `cell` is the geoid's cell the state is read in (`Cells.of`); without one, the cell where the state
    /// is.
    pub fn of(state: shared_trajectory.State, datum: Altitude, cell: ?*const core.geoid.Cell) Reading {
        const frame: Frame = .at(positionJet(state.pos, state.vel, state.acc));
        const height = switch (datum) {
            .ellipsoid => frame.height,
            .egm96 => frame.height.sub(if (cell) |c| geoidHeight(c, frame.up) else core.geoid.Evaluator(Jet, Jet.Arithmetic).height(frame.up)),
        };
        const east = values(frame.east);
        const north = values(frame.north);
        const horizontal = std.math.hypot(state.vel.dot(east), state.vel.dot(north));
        const moving = horizontal >= moving_mps;
        const ahead: [2]f64 = .{ state.vel.dot(east) / horizontal, state.vel.dot(north) / horizontal };
        const forward = state.acc.dot(east) * ahead[0] + state.acc.dot(north) * ahead[1];
        const lateral = state.acc.dot(east) * ahead[1] - state.acc.dot(north) * ahead[0];
        return .{
            .altitude_m = height.value,
            .climb_mps = height.first,
            .vertical_acceleration_mps2 = height.second,
            .speed_mps = state.vel.norm(),
            .horizontal_speed_mps = horizontal,
            .acceleration_mps2 = state.acc.norm(),
            .jerk_mps3 = state.jerk.norm(),
            .course_deg = if (moving) courseDeg(std.math.atan2(ahead[0], ahead[1])) else null,
            .turn_rate_degps = if (moving) finite(constants.rad2deg(lateral / horizontal)) else null,
            .forward_acceleration_mps2 = if (moving) finite(forward) else null,
            .forward_jerk_mps3 = if (moving) finite(state.jerk.dot(east) * ahead[0] + state.jerk.dot(north) * ahead[1]) else null,
            .lateral_acceleration_mps2 = if (moving) finite(lateral) else null,
        };
    }
};

/// The geoid's cells the points of a stored path are read in over EGM96, the last one kept while the points stay in
/// it.
pub const Cells = struct {
    last: ?core.geoid.Cell = null,

    /// The cell a point at the time t of the piece from k0 to k1 is read in: the one it lies in; at a knot, the one its
    /// piece lies in next to it, a millimetre in (or at a shorter piece's middle), so that the two knots at a grid line
    /// read their own sides.
    pub fn of(self: *Cells, k0: shared_trajectory.Knot, k1: shared_trajectory.Knot, t: f64, pos: core.coord.Ecef) *const core.geoid.Cell {
        if (k1.t == k0.t or (t != k0.t and t != k1.t)) return self.at(pos);
        const in = @min(0.5, knot_inset_m / k1.pos.sub(k0.pos).norm()) * (k1.t - k0.t);
        return self.at(shared_trajectory.between(k0, k1, if (t == k0.t) k0.t + in else k1.t - in).pos);
    }

    fn at(self: *Cells, pos: core.coord.Ecef) *const core.geoid.Cell {
        const p = core.coord.ecefToLla(pos);
        if (self.last == null or !self.last.?.contains(p.lat_rad, p.lon_rad)) self.last = .at(p.lat_rad, p.lon_rad);
        return &self.last.?;
    }
};

/// Far above the rounding of a position, far below the 61 m a grid step of the geoid spans at its polar caps.
const knot_inset_m = 1e-3;

/// A vector's values, without their rates.
fn values(v: Vector) core.coord.Ecef {
    return .{ .x = v[0].value, .y = v[1].value, .z = v[2].value };
}

/// The geoid's height by a cell, with its rates as the normal moves.
fn geoidHeight(cell: *const core.geoid.Cell, up: Vector) Jet {
    const local = cell.surface(values(up));
    const n1: core.coord.Ecef = .{ .x = up[0].first, .y = up[1].first, .z = up[2].first };
    const n2: core.coord.Ecef = .{ .x = up[0].second, .y = up[1].second, .z = up[2].second };
    return .{ .value = local.height, .first = local.rate(n1), .second = local.curvature(n1, n2) };
}

/// A rate of a path far outside the receiver's domain can overflow: it then has no value.
fn finite(x: f64) ?f64 {
    return if (std.math.isFinite(x)) x else null;
}
