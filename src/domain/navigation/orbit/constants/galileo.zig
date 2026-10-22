const std = @import("std");
const orbit_constants = @import("domain/navigation/orbit/constants");

pub const a_ref: f64 = 29_600_000.0;
pub const sqrt_a_ref: f64 = 5440.588203494177338011974948823;
pub const nominal_i0: f64 = 56.0 * std.math.pi / 180.0;

pub const orbit: orbit_constants.SystemConstants = .{
    .mu = 3.986004418e14,
    .omega_e = 7.2921151467e-5,
};
