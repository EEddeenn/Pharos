//! A trajectory plan as read: the places and guides, the start and the ordered segments, every place in ECEF, every
//! angle in radians, every time in seconds from the start, and the events that the plan names.
const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const dictionary = @import("base/text/dictionary");

pub const Vector = coordinates.Ecef;

pub const Altitude = enum {
    egm96,
    ellipsoid,

    pub const words: std.EnumArray(Altitude, []const u8) = .init(.{ .egm96 = "EGM96", .ellipsoid = "ellipsoid" });
};

pub const Place = struct {
    id: []const u8,
    ecef: Vector,
    /// The ellipsoidal height, as the plan gives it.
    height: f64,
    /// The height above the plan's altitude reference, as the plan gives it.
    altitude: f64,
};

pub const Guide = struct {
    id: []const u8,
    /// The places it is drawn through, by index.
    places: []const usize,
    shape: union(enum) {
        /// Legs from place to place, each corner rounded by an arc of this radius, in metres.
        polyline: f64,
        /// Cubic pieces of four places each, a piece's last place the next one's first.
        bezier,
    },
};

/// How the path begins: its horizontal speed over the ground (0 at rest; null free, the first segment's to choose)
/// and its course, where the plan gives one.
pub const Start = struct {
    speed: ?f64,
    course: ?f64,
};

pub const End = enum {
    free,
    rest,

    pub const words = dictionary.tagNames(End);
};

pub const Visit = struct {
    place: usize,
    time: f64,
};

pub const Kind = enum {
    stay,
    straight,
    turn,
    along,
    through,

    pub const words = dictionary.tagNames(Kind);
};

/// How long a segment lasts, where the plan says: its duration, or the time it ends.
pub const Span = union(enum) {
    duration: f64,
    until: f64,
};

/// The time or end speed of a segment whose shape fixes its ground length.
pub const FixedMotion = union(enum) {
    keep_speed,
    end_speed_mps: f64,
    span: Span,
};

pub const TimedMotion = struct {
    span: Span,
    end_speed_mps: ?f64,
};

pub const VerticalGoal = struct {
    climb_mps: ?f64 = null,
    altitude_m: ?f64 = null,
};

pub const Straight = union(enum) {
    to: struct { place: usize, motion: FixedMotion, climb_mps: ?f64 },
    distance: struct { course_rad: ?f64, distance_m: f64, motion: FixedMotion, vertical: VerticalGoal },
    timed: struct { course_rad: ?f64, motion: TimedMotion, vertical: VerticalGoal },
};

pub const AngularEnd = union(enum) { onto_rad: f64, by_rad: f64 };

pub const Turn = union(enum) {
    radius: struct {
        radius_m: f64,
        extent: union(enum) {
            timed: TimedMotion,
            angular: struct { end: AngularEnd, motion: FixedMotion },
        },
        vertical: VerticalGoal,
    },
    steady: struct {
        bend: union(enum) { rate_radps: f64, lateral_mps2: f64 },
        end: union(enum) { span: Span, angular: AngularEnd },
        speed_mps: ?f64,
        vertical: VerticalGoal,
    },
};

/// A part of a guide, from one place to a later place by their indices in the guide.
pub const Along = struct {
    guide: usize,
    from: usize,
    to: usize,
    motion: FixedMotion,
};

pub const Through = struct {
    visits: []const Visit,
    end: End,
};

pub const Segment = struct {
    id: ?[]const u8,
    motion: union(Kind) {
        stay: Span,
        straight: Straight,
        turn: Turn,
        along: Along,
        through: Through,
    },
};

pub const Event = struct {
    name: []const u8,
    target: union(enum) {
        start,
        segment_end: usize,
        visit: struct { segment: usize, visit: usize },
    },
};

/// What a limit bounds, read off the stored path at its height: speeds in m/s, accelerations in m/s^2, the jerk in
/// m/s^3, the altitude in metres in the plan's reference.
pub const Quantity = enum {
    speed3d,
    horizontal_speed,
    acceleration3d,
    jerk3d,
    lateral_acceleration,
    forward_acceleration,
    climb_rate,
    vertical_acceleration,
    altitude,

    pub const words: std.EnumArray(Quantity, []const u8) = .init(.{
        .speed3d = "speed3d",
        .horizontal_speed = "horizontalSpeed",
        .acceleration3d = "acceleration3d",
        .jerk3d = "jerk3d",
        .lateral_acceleration = "lateralAcceleration",
        .forward_acceleration = "forwardAcceleration",
        .climb_rate = "climbRate",
        .vertical_acceleration = "verticalAcceleration",
        .altitude = "altitude",
    });

    /// The quantity in a sentence.
    pub const names: std.EnumArray(Quantity, []const u8) = .init(.{
        .speed3d = "the 3D speed",
        .horizontal_speed = "the horizontal speed",
        .acceleration3d = "the 3D acceleration",
        .jerk3d = "the 3D jerk",
        .lateral_acceleration = "the lateral acceleration",
        .forward_acceleration = "the forward acceleration",
        .climb_rate = "the climb rate",
        .vertical_acceleration = "the vertical acceleration",
        .altitude = "the altitude",
    });

    pub const Family = enum { speed, acceleration, jerk, altitude };

    pub fn family(self: Quantity) Family {
        return switch (self) {
            .speed3d, .horizontal_speed, .climb_rate => .speed,
            .acceleration3d, .lateral_acceleration, .forward_acceleration, .vertical_acceleration => .acceleration,
            .jerk3d => .jerk,
            .altitude => .altitude,
        };
    }

    /// Whether it has a sign, which its limit leaves aside: it bounds the size.
    pub fn signed(self: Quantity) bool {
        return switch (self) {
            .lateral_acceleration, .forward_acceleration, .climb_rate, .vertical_acceleration => true,
            else => false,
        };
    }

    pub fn unit(self: Quantity) []const u8 {
        return switch (self.family()) {
            .speed => "m/s",
            .acceleration => "m/s^2",
            .jerk => "m/s^3",
            .altitude => "m",
        };
    }
};

pub const Bounds = union(enum) {
    maximum: f64,
    minimum: f64,
    between: struct { min: f64, max: f64 },

    pub fn min(self: Bounds) ?f64 {
        return switch (self) {
            .maximum => null,
            .minimum => |value| value,
            .between => |range| range.min,
        };
    }

    pub fn max(self: Bounds) ?f64 {
        return switch (self) {
            .minimum => null,
            .maximum => |value| value,
            .between => |range| range.max,
        };
    }
};

/// A bound on selected segments, or on the whole stored path. Signed quantities are bounded by their size.
pub const Limit = struct {
    id: ?[]const u8,
    quantity: Quantity,
    bounds: Bounds,
    over: ?[]const usize,
};

pub const Plan = struct {
    name: []const u8,
    altitude: Altitude,
    places: []const Place,
    guides: []const Guide,
    start_place: usize,
    start: Start,
    segments: []const Segment,
    events: []const Event,
    limits: []const Limit,
};
