const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const coord = core.coord;
const trajectory = shared.trajectory;

pub const max_latitude_deg: f64 = 90;
pub const max_longitude_deg: f64 = 180;

pub const Placement = union(enum) {
    lla: struct { lat_deg: f64, lon_deg: f64, altitude_m: f64 },
    ecef: coord.Ecef,
};

pub const Error = error{ OutOfMemory, LatitudeOutOfRange, LongitudeOutOfRange, PositionOutOfRange, DurationOutOfRange };

pub fn build(arena: std.mem.Allocator, name: []const u8, at: Placement, duration_s: f64) Error!trajectory.Trajectory {
    const position = switch (at) {
        .lla => |p| blk: {
            if (!(@abs(p.lat_deg) <= max_latitude_deg)) return error.LatitudeOutOfRange;
            if (!(@abs(p.lon_deg) <= max_longitude_deg)) return error.LongitudeOutOfRange;
            break :blk coord.llaToEcef(core.geoid.lla(core.constants.deg2rad(p.lat_deg), core.constants.deg2rad(p.lon_deg), p.altitude_m));
        },
        .ecef => |ecef| ecef,
    };
    if (!trajectory.positionInRange(position)) return error.PositionOutOfRange;
    if (!(duration_s >= 0 and duration_s <= trajectory.max_duration_s)) return error.DurationOutOfRange;
    const zero: coord.Ecef = .{ .x = 0, .y = 0, .z = 0 };
    const knots = try arena.alloc(trajectory.Knot, if (duration_s > 0) 2 else 1);
    for (knots, 0..) |*knot, i| knot.* = .{ .t = if (i == 0) 0 else duration_s, .pos = position, .vel = zero, .acc = zero };
    return .{ .name = name, .knots = knots };
}
