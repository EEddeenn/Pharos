const std = @import("std");
const attitude = @import("domain/earth/attitude");
const angles = @import("base/math/angles");

const block_iif_yaw_rate_deg_per_s: f64 = 0.11;
const block_iir_yaw_rate_deg_per_s: f64 = 0.2;
const block_ii_yaw_rate_deg_per_s: f64 = 0.1211;
const glonass_yaw_rate_deg_per_s: f64 = 0.25;
const galileo_iov_beta_floor_deg: f64 = 2;
const galileo_iov_along_limit_deg: f64 = 15;
const galileo_foc_beta_limit_deg: f64 = 4.1;
const galileo_foc_colinearity_deg: f64 = 10;
const galileo_foc_period_s: f64 = 5656;
const beidou_2_orbit_normal_beta_deg: f64 = 3;
const beidou_3_beta_floor_deg: f64 = 3;

pub fn lawOf(kind: []const u8) attitude.Law {
    const rows = [_]struct { prefix: []const u8, law: attitude.Law }{
        .{ .prefix = "BLOCK III", .law = attitude.Law{ .rate_limited = angles.deg2rad(block_iif_yaw_rate_deg_per_s) } },
        .{ .prefix = "BLOCK IIR", .law = attitude.Law{ .rate_limited = angles.deg2rad(block_iir_yaw_rate_deg_per_s) } },
        .{ .prefix = "BLOCK IIF", .law = attitude.Law{ .rate_limited = angles.deg2rad(block_iif_yaw_rate_deg_per_s) } },
        .{ .prefix = "BLOCK II", .law = attitude.Law{ .rate_limited = angles.deg2rad(block_ii_yaw_rate_deg_per_s) } },
        .{ .prefix = "GLONASS-M", .law = attitude.Law{ .shadowed = angles.deg2rad(glonass_yaw_rate_deg_per_s) } },
        .{ .prefix = "GLONASS", .law = attitude.Law{ .rate_limited = angles.deg2rad(glonass_yaw_rate_deg_per_s) } },
        .{ .prefix = "GALILEO-1", .law = attitude.Law{ .auxiliary = .{ .beta_rad = angles.deg2rad(galileo_iov_beta_floor_deg), .along_rad = angles.deg2rad(galileo_iov_along_limit_deg) } } },
        .{ .prefix = "GALILEO", .law = attitude.Law{ .smoothed = .{ .beta_rad = angles.deg2rad(galileo_foc_beta_limit_deg), .colinearity_rad = angles.deg2rad(galileo_foc_colinearity_deg), .period_s = galileo_foc_period_s } } },
        .{ .prefix = "BEIDOU-2G", .law = attitude.Law.orbit_normal },
        .{ .prefix = "BEIDOU-3G", .law = attitude.Law.orbit_normal },
        .{ .prefix = "BEIDOU-2", .law = attitude.Law{ .orbit_normal_below = angles.deg2rad(beidou_2_orbit_normal_beta_deg) } },
        .{ .prefix = "BEIDOU-3M-SECM", .law = attitude.Law{ .beta_floor = angles.deg2rad(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3M-CAST", .law = attitude.Law{ .beta_floor = angles.deg2rad(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3SM-CAST", .law = attitude.Law{ .beta_floor = angles.deg2rad(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3I", .law = attitude.Law{ .beta_floor = angles.deg2rad(beidou_3_beta_floor_deg) } },
        .{ .prefix = "BEIDOU-3SI-CAST", .law = attitude.Law{ .beta_floor = angles.deg2rad(beidou_3_beta_floor_deg) } },
    };
    for (rows) |row| if (std.mem.startsWith(u8, kind, row.prefix)) return row.law;
    return .nominal;
}
