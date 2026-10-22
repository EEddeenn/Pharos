const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const trajectory = @import("domain/trajectory/trajectory");
const angles = @import("base/math/angles");
const geoid = @import("domain/earth/geoid/model");

const Range = @import("base/math/range").Range;

pub const latitude_range: Range = .{ .min = -90, .max = 90 };
pub const longitude_range: Range = .{ .min = -180, .max = 180 };
pub const duration_range: Range = .{ .min = 0, .max = trajectory.max_duration_s };

pub const Placement = union(enum) {
    lla: struct { lat_deg: f64, lon_deg: f64, altitude_m: f64 },
    ecef: coordinates.Ecef,
};

pub const Error = error{ OutOfMemory, LatitudeOutOfRange, LongitudeOutOfRange, PositionOutOfRange, DurationOutOfRange };

pub fn build(arena: std.mem.Allocator, name: []const u8, at: Placement, duration_s: f64) Error!trajectory.Trajectory {
    const position = switch (at) {
        .lla => |p| blk: {
            if (!latitude_range.holds(p.lat_deg)) return error.LatitudeOutOfRange;
            if (!longitude_range.holds(p.lon_deg)) return error.LongitudeOutOfRange;
            break :blk coordinates.llaToEcef(geoid.lla(angles.deg2rad(p.lat_deg), angles.deg2rad(p.lon_deg), p.altitude_m));
        },
        .ecef => |ecef| ecef,
    };
    if (!trajectory.positionInRange(position)) return error.PositionOutOfRange;
    if (!duration_range.holds(duration_s)) return error.DurationOutOfRange;
    const zero: coordinates.Ecef = .{ .x = 0, .y = 0, .z = 0 };
    const knots = try arena.alloc(trajectory.Knot, if (duration_s > 0) 2 else 1);
    for (knots, 0..) |*knot, i| knot.* = .{ .t = if (i == 0) 0 else duration_s, .pos = position, .vel = zero, .acc = zero };
    return .{ .name = name, .knots = knots };
}
