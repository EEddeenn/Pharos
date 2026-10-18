const model = @import("model.zig");

pub const Dimension = enum { time, length, speed, acceleration, jerk, angle, angular_rate };

pub fn components(quantity: model.Quantity) usize {
    return switch (quantity) {
        .position, .velocity_ecef, .acceleration_ecef => 3,
        else => 1,
    };
}

pub fn dimension(quantity: model.Quantity) Dimension {
    return switch (quantity) {
        .time, .duration => .time,
        .altitude, .turn_radius, .position => .length,
        .speed3d, .horizontal_speed, .forward_speed, .climb_rate, .velocity_ecef => .speed,
        .forward_acceleration, .vertical_acceleration, .acceleration3d, .lateral_acceleration, .acceleration_ecef => .acceleration,
        .forward_jerk, .jerk3d => .jerk,
        .course => .angle,
        .turn_rate => .angular_rate,
    };
}

/// The quantities that hang on the direction of travel: they have no value where the path is at rest.
pub fn directed(quantity: model.Quantity) bool {
    return switch (quantity) {
        .course, .turn_rate, .turn_radius, .forward_acceleration, .forward_jerk, .lateral_acceleration => true,
        else => false,
    };
}

pub fn interval(scope: model.Scope) bool {
    return switch (scope) {
        .section, .between, .time_range, .all => true,
        .event, .time => false,
    };
}

pub fn scopeAllowed(quantity: model.Quantity, scope: model.Scope) bool {
    return switch (quantity) {
        .time => scope == .event,
        .duration => interval(scope),
        else => true,
    };
}

pub fn compatible(a: model.Quantity, b: model.Quantity) bool {
    return components(a) == components(b) and dimension(a) == dimension(b);
}
