const std = @import("std");
const Ecef = @import("coord.zig").Ecef;

pub const Elements = struct {
    a: f64,
    p: f64,
    ecc: f64,
    i: f64,
    node: f64,
    e_anomaly: f64,
    true_anomaly: f64,
    arg_lat: f64,
};

pub fn normAngle(a: f64) f64 {
    return @mod(a + std.math.pi, 2.0 * std.math.pi) - std.math.pi;
}

pub fn inertial(vel: Ecef, pos: Ecef, omega_e: f64) Ecef {
    return .{ .x = vel.x - omega_e * pos.y, .y = vel.y + omega_e * pos.x, .z = vel.z };
}

pub fn fromState(pos: Ecef, vel_i: Ecef, mu: f64) ?Elements {
    const h = pos.cross(vel_i);
    const h_xy = std.math.hypot(h.x, h.y);
    const h2 = h.dot(h);
    const r = pos.norm();
    const v2 = vel_i.dot(vel_i);
    const rv = pos.dot(vel_i);
    const a = 1.0 / (2.0 / r - v2 / mu);
    if (a <= 0) return null;
    const p = h2 / mu;
    const ecc = if (a > p) @sqrt(1.0 - p / a) else 0.0;
    const e_anomaly = std.math.atan2(rv / @sqrt(mu * a), 1.0 - r / a);
    const true_anomaly = std.math.atan2(@sqrt(1.0 - ecc * ecc) * @sin(e_anomaly), @cos(e_anomaly) - ecc);
    return .{
        .a = a,
        .p = p,
        .ecc = ecc,
        .i = std.math.atan2(h_xy, h.z),
        .node = std.math.atan2(h.x, -h.y),
        .e_anomaly = e_anomaly,
        .true_anomaly = true_anomaly,
        .arg_lat = std.math.atan2(pos.z * @sqrt(h2), pos.y * h.x - pos.x * h.y),
    };
}
