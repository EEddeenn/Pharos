const std = @import("std");
const angles = @import("base/math/angles");

const Ecef = @import("domain/earth/coordinates").Ecef;

pub const rows = 721;
pub const columns = 1440;
pub const spacing_deg = 0.25;
pub const cap_steps = 0.5;
pub const first_slope_line = 2;
pub const last_slope_line = rows - 3;

const cap_outer_radius = @sin(angles.deg2rad(spacing_deg));
const cap_inner_radius = @sin(angles.deg2rad(spacing_deg * cap_steps));
pub const cap_outer_squared = cap_outer_radius * cap_outer_radius;
pub const cap_inner_squared = cap_inner_radius * cap_inner_radius;

pub const Grid = struct {
    y: f64,
    x: f64,
    south: usize,
    west: i64,

    pub fn of(lat_rad: f64, lon_rad: f64) Grid {
        const g = coordinates(lat_rad, lon_rad);
        return .{
            .y = g[0],
            .x = g[1],
            .south = @intFromFloat(std.math.clamp(@floor(g[0]) - 1, 0, rows - 4)),
            .west = @as(i64, @intFromFloat(@floor(g[1]))) - 1,
        };
    }
};

/// Latitude steps from the south pole and longitude steps east from zero.
pub fn coordinatesOf(normal: Ecef) [2]f64 {
    return coordinates(std.math.atan2(normal.z, @sqrt(normal.x * normal.x + normal.y * normal.y)), std.math.atan2(normal.y, normal.x));
}

fn coordinates(lat_rad: f64, lon_rad: f64) [2]f64 {
    const lat = std.math.clamp(angles.rad2deg(lat_rad), -90.0, 90.0);
    const lon = @mod(angles.rad2deg(lon_rad), 360.0);
    return .{ (lat + 90.0) / spacing_deg, lon / spacing_deg };
}
