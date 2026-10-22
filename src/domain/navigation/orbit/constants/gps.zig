const std = @import("std");
const orbit_constants = @import("domain/navigation/orbit/constants");

pub const orbit: orbit_constants.SystemConstants = .{
    .mu = 3.986005e14,
    .omega_e = 7.2921151467e-5,
};

pub const a_ref: f64 = 26_559_710.0;
pub const omega_dot_ref: f64 = -2.6e-9;
pub const nominal_i0: f64 = 0.3 * std.math.pi;
