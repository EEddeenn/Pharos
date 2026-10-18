//! A trajectory plan as read: the start and the ordered segments, every place in ECEF and every time in seconds
//! from the start, and the events that the plan names.
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
};

/// How the path begins: at rest, free (its velocity and acceleration the first segment's to choose), or at a stated
/// horizontal velocity, its acceleration free.
pub const Start = union(enum) {
    rest,
    free,
    moving: Vector,
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
    through,

    pub const words = core.dictionary.tagNames(Kind);
};

pub const Segment = struct {
    id: ?[]const u8,
    /// The time it ends.
    end: f64,
    motion: union(Kind) {
        stay,
        through: struct { visits: []const Visit, end: End },
    },
};

/// A named instant: the start, a place a through visits, the end of a segment with an id.
pub const Event = struct {
    name: []const u8,
    time: f64,
    /// The segment it belongs to, and the visit of a through; null for the start.
    segment: ?usize,
    visit: ?usize = null,
};

pub const Plan = struct {
    name: []const u8,
    altitude: Altitude,
    places: []const Place,
    start_place: usize,
    start: Start,
    segments: []const Segment,
    events: []const Event,
};
