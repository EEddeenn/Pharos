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

pub const Plan = struct {
    name: []const u8,
    altitude: Altitude,
    places: []const Place,
    guides: []const Guide,
    start_place: usize,
    start: Start,
    segments: []const Segment,
    events: []const Event,
};
