const std = @import("std");
const constants = @import("constants.zig");
const Ecef = @import("coord.zig").Ecef;
const elements = @import("elements.zig");

pub const Law = union(enum) {
    nominal,
    rate_limited: f64,
    shadowed: f64,
    smoothed: Smoothed,
    auxiliary: Auxiliary,
    beta_floor: f64,
    orbit_normal_below: f64,
    orbit_normal,
};

const Smoothed = struct { beta_rad: f64, colinearity_rad: f64, period_s: f64 };

const Auxiliary = struct { beta_rad: f64, along_rad: f64 };

const bisection_steps = 48;
const min_rate_ratio: f64 = 2.0;

fn limitEntryCos(slope: f64, k: f64) f64 {
    return (-slope + @sqrt(slope * slope + 4.0 * k * k * (slope * slope + 1.0))) / (2.0 * k);
}

pub const BodyAxes = struct {
    x: Ecef,
    y: Ecef,
    z: Ecef,

    /// Null for a satellite with no orbit plane (its inertial velocity along its radius, or none): no yaw is defined.
    pub fn of(law: Law, sat_pos: Ecef, sat_vel: Ecef, omega_e: f64, sun_pos: Ecef) ?BodyAxes {
        const g = Geometry.of(sat_pos, sat_vel, omega_e, sun_pos) orelse return null;
        return g.at(g.yaw(law));
    }

    pub fn toEcef(self: BodyAxes, body: [3]f64) Ecef {
        return self.x.scale(body[0]).add(self.y.scale(body[1])).add(self.z.scale(body[2]));
    }
};

const Geometry = struct {
    z: Ecef,
    along: Ecef,
    cross: Ecef,
    beta_rad: f64,
    mu_rad: f64,
    rate: f64,
    radius_m: f64,

    fn of(sat_pos: Ecef, sat_vel: Ecef, omega_e: f64, sun_pos: Ecef) ?Geometry {
        const r = sat_pos.norm();
        const inertial = elements.inertial(sat_vel, sat_pos, omega_e);
        const moment = sat_pos.cross(inertial);
        if (!(moment.norm() > 0)) return null;
        const z = sat_pos.scale(-1.0 / r);
        const a = z.cross(moment.unit()).unit();
        const b = z.cross(a);
        const s = sun_pos.sub(sat_pos).unit();
        const along = s.dot(a);
        const normal = s.dot(b);
        return .{
            .z = z,
            .along = a,
            .cross = b,
            .beta_rad = std.math.asin(@max(-1.0, @min(1.0, -normal))),
            .mu_rad = std.math.atan2(along, s.dot(z)),
            .rate = moment.norm() / (r * r),
            .radius_m = r,
        };
    }

    fn at(self: Geometry, psi: f64) BodyAxes {
        const x = self.along.scale(@cos(psi)).add(self.cross.scale(@sin(psi)));
        return .{ .x = x, .y = self.z.cross(x), .z = self.z };
    }

    fn yaw(self: Geometry, law: Law) f64 {
        const turn: Turn = .of(self.mu_rad);
        return switch (law) {
            .nominal => self.nominalYaw(turn, turn.nu_rad),
            .orbit_normal => 0,
            .orbit_normal_below => |threshold| if (@abs(self.beta_rad) <= threshold) 0 else self.nominalYaw(turn, turn.nu_rad),
            .beta_floor => |floor| yawOf(std.math.copysign(@max(@abs(self.beta_rad), floor), self.beta_rad), turn, turn.nu_rad),
            .rate_limited => |rad_per_s| self.rateLimited(turn, rad_per_s),
            .shadowed => |rad_per_s| self.shadowed(turn, rad_per_s),
            .smoothed => |s| self.smoothed(turn, s),
            .auxiliary => |a| self.auxiliary(turn, a),
        };
    }

    fn nominalYaw(self: Geometry, turn: Turn, nu: f64) f64 {
        return yawOf(self.beta_rad, turn, nu);
    }

    fn rateLimited(self: Geometry, turn: Turn, rad_per_s: f64) f64 {
        const k = rad_per_s / self.rate;
        const c = limitEntryCos(@abs(@tan(self.beta_rad)), k);
        if (!(c < 1.0) or !(k > min_rate_ratio)) return self.nominalYaw(turn, turn.nu_rad);
        const nu0 = std.math.acos(c);
        if (turn.nu_rad < -nu0) return self.nominalYaw(turn, turn.nu_rad);
        const entry = self.nominalYaw(turn, -nu0);
        const dir: f64 = if (self.beta_rad < 0) -turn.sign else turn.sign;
        var lo = nu0;
        var hi = @min(constants.pi / 2.0, nu0 + constants.pi / k);
        for (0..bisection_steps) |_| {
            const mid = 0.5 * (lo + hi);
            if (k * (mid + nu0) < self.sweep(turn, mid, entry, dir)) lo = mid else hi = mid;
        }
        if (turn.nu_rad > hi) return self.nominalYaw(turn, turn.nu_rad);
        return entry + dir * k * (turn.nu_rad + nu0);
    }

    fn sweep(self: Geometry, turn: Turn, nu: f64, entry: f64, dir: f64) f64 {
        return @mod(dir * (self.nominalYaw(turn, nu) - entry), constants.two_pi);
    }

    fn shadowed(self: Geometry, turn: Turn, rad_per_s: f64) f64 {
        const k = rad_per_s / self.rate;
        if (turn.sign < 0) return self.centred(turn, k);
        const umbra = self.umbraHalf() orelse return self.nominalYaw(turn, turn.nu_rad);
        if (turn.nu_rad < -umbra) return self.nominalYaw(turn, turn.nu_rad);
        const entry = self.nominalYaw(turn, -umbra);
        const dir: f64 = if (self.beta_rad < 0) -turn.sign else turn.sign;
        const need = self.sweep(turn, umbra, entry, dir);
        const reached = -umbra + need / k;
        if (!(reached < umbra)) return self.rateLimited(turn, rad_per_s);
        if (turn.nu_rad <= reached) return entry + dir * k * (turn.nu_rad + umbra);
        if (turn.nu_rad < umbra) return entry + dir * need;
        return self.nominalYaw(turn, turn.nu_rad);
    }

    fn umbraHalf(self: Geometry) ?f64 {
        const radius = std.math.asin(@min(1.0, constants.wgs_axis_a / self.radius_m));
        const c = @cos(radius) / @cos(self.beta_rad);
        if (!(c <= 1.0)) return null;
        return std.math.acos(c);
    }

    fn centred(self: Geometry, turn: Turn, k: f64) f64 {
        if (@abs(@tan(self.beta_rad)) >= 1.0 / k) return self.nominalYaw(turn, turn.nu_rad);
        const centre = std.math.atan2(-@sin(self.beta_rad), 0.0);
        var lo: f64 = 0;
        var hi: f64 = constants.pi / 2.0;
        for (0..bisection_steps) |_| {
            const mid = 0.5 * (lo + hi);
            if (@abs(elements.normAngle(self.nominalYaw(turn, -mid) - centre)) > k * mid) lo = mid else hi = mid;
        }
        if (@abs(turn.nu_rad) > hi) return self.nominalYaw(turn, turn.nu_rad);
        return centre - elements.normAngle(self.nominalYaw(turn, -hi) - centre) * (turn.nu_rad / hi);
    }

    fn smoothed(self: Geometry, turn: Turn, s: Smoothed) f64 {
        if (@abs(self.beta_rad) > s.beta_rad) return self.nominalYaw(turn, turn.nu_rad);
        const start = -std.math.acos(@min(1.0, @cos(s.colinearity_rad) / @cos(self.beta_rad)));
        const half_period_rad = self.rate * s.period_s / 2.0;
        if (turn.nu_rad < start or turn.nu_rad > start + half_period_rad) return self.nominalYaw(turn, turn.nu_rad);
        const centre = std.math.atan2(-@sin(self.beta_rad), 0.0);
        const entry = elements.normAngle(self.nominalYaw(turn, start) - centre);
        return centre + entry * @cos(constants.pi * (turn.nu_rad - start) / half_period_rad);
    }

    fn auxiliary(self: Geometry, turn: Turn, aux: Auxiliary) f64 {
        const along = @cos(self.beta_rad) * turn.sign * @sin(turn.nu_rad);
        const normal = -@sin(self.beta_rad);
        const along_limit = @sin(aux.along_rad);
        const normal_limit = @sin(aux.beta_rad);
        if (@abs(along) >= along_limit or @abs(normal) >= normal_limit) return self.nominalYaw(turn, turn.nu_rad);
        const held = std.math.copysign(normal_limit, normal);
        const blend = @cos(constants.pi * @abs(along) / along_limit);
        return std.math.atan2(0.5 * (held + normal) + 0.5 * (held - normal) * blend, along);
    }
};

const Turn = struct {
    nu_rad: f64,
    sign: f64,

    fn of(mu_rad: f64) Turn {
        const m = elements.normAngle(mu_rad);
        if (@abs(m) <= constants.pi / 2.0) return .{ .nu_rad = m, .sign = 1 };
        return .{ .nu_rad = elements.normAngle(m - constants.pi), .sign = -1 };
    }
};

fn yawOf(beta_rad: f64, turn: Turn, nu: f64) f64 {
    return std.math.atan2(-@sin(beta_rad), @cos(beta_rad) * turn.sign * @sin(nu));
}
