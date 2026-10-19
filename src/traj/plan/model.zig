//! A trajectory plan as read: the places and guides, the start and the ordered segments, every place in ECEF, every
//! angle in radians, every time in seconds from the start, and the events that the plan names.
const std = @import("std");
const core = @import("shared").core;

pub const Vector = core.coord.Ecef;

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

    pub const words = core.dictionary.tagNames(End);
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

    pub const words = core.dictionary.tagNames(Kind);
};

/// How long a segment lasts, where the plan says: its duration, or the time it ends.
pub const Span = union(enum) {
    duration: f64,
    until: f64,
};

/// A turn's constant geodesic curvature, signed + to the right: by its radius (m), its rate (rad/s) or its lateral
/// acceleration (m/s^2), the last two at the speed the turn keeps.
pub const Bend = union(enum) {
    radius: f64,
    rate: f64,
    lateral: f64,
};

pub const Straight = struct {
    /// The initial azimuth, where the plan gives it.
    course: ?f64,
    /// The place it ends at.
    to: ?usize,
    /// Its length over the ground, in metres.
    distance: ?f64,
};

pub const Turn = struct {
    bend: Bend,
    /// Where it ends: when its course reaches an azimuth, or when it has turned through a signed angle (its length
    /// times its curvature); neither where its time ends it.
    end: union(enum) { open, onto: f64, by: f64 },
};

/// A part of a guide: from one of its places to a later one, each by its position in the guide's places.
pub const Along = struct {
    guide: usize,
    from: usize,
    to: usize,
};

pub const Segment = struct {
    id: ?[]const u8,
    span: ?Span,
    /// The horizontal speed over the ground it ends at, in m/s.
    speed: ?f64,
    /// The rate of altitude it ends at, in m/s.
    climb: ?f64,
    /// The altitude it ends at, in the plan's reference.
    altitude: ?f64,
    motion: union(Kind) {
        stay,
        straight: Straight,
        turn: Turn,
        along: Along,
        through: struct { visits: []const Visit, end: End },
    },
};

/// A named instant: the start, a place a through visits, the end of a segment with an id.
pub const Event = struct {
    name: []const u8,
    /// The segment it belongs to, and the visit of a through; null for the start.
    segment: ?usize,
    visit: ?usize = null,
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

/// A check of the built path: its quantity at most `max` (in size, for a signed one) and at least `min`, over the
/// segments named (by index), or over all.
pub const Limit = struct {
    id: ?[]const u8,
    quantity: Quantity,
    max: ?f64,
    min: ?f64,
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
