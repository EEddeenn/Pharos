const std = @import("std");
const core = @import("shared").core;

pub const Vector = core.coord.Ecef;

pub const Altitude = enum {
    egm96,
    ellipsoid,

    pub const words: std.EnumArray(Altitude, []const u8) = .init(.{ .egm96 = "EGM96", .ellipsoid = "ellipsoid" });
};

pub const Coordinates = struct {
    altitude: Altitude,
};

pub const Position = struct {
    latitude: f64,
    longitude: f64,
    altitude: f64,
};

pub const Point = struct {
    id: []const u8,
    ecef: Vector,
};

pub const CurveKind = enum {
    bezier,
    polyline,

    pub const words = core.dictionary.tagNames(CurveKind);
};

pub const Curve = struct {
    id: []const u8,
    kind: CurveKind,
    points: []const usize,
};

pub const Region = struct {
    id: []const u8,
    shape: union(enum) {
        circle: struct { center: usize, radius: f64 },
        polygon: []const usize,
    },
};

pub const Geometry = struct {
    points: []const Point,
    curves: []const Curve,
    regions: []const Region,
};

pub const Continuity = enum {
    c0,
    c1,
    c2,

    pub const words: std.EnumArray(Continuity, []const u8) = .init(.{ .c0 = "C0", .c1 = "C1", .c2 = "C2" });
};

pub const Event = struct {
    id: []const u8,
    continuity: Continuity = .c2,
};

pub const Section = struct {
    id: []const u8,
};

/// The least a section may last, in seconds.
pub const min_section_s: f64 = 1e-3;

pub const Side = enum {
    in,
    out,

    pub const words = core.dictionary.tagNames(Side);
};

pub const EventRef = struct {
    index: usize,
    side: Side = .out,
};

pub const Scope = union(enum) {
    event: EventRef,
    section: usize,
    between: [2]usize,
    time: f64,
    time_range: [2]f64,
    all,
};

pub const Quantity = enum(u8) {
    time,
    duration,
    speed3d,
    horizontal_speed,
    forward_speed,
    forward_acceleration,
    forward_jerk,
    climb_rate,
    vertical_acceleration,
    acceleration3d,
    jerk3d,
    altitude,
    course,
    turn_rate,
    lateral_acceleration,
    turn_radius,
    position,
    velocity_ecef,
    acceleration_ecef,

    pub const words: std.EnumArray(Quantity, []const u8) = .init(.{
        .time = "time",
        .duration = "duration",
        .speed3d = "speed3d",
        .horizontal_speed = "horizontalSpeed",
        .forward_speed = "forwardSpeed",
        .forward_acceleration = "forwardAcceleration",
        .forward_jerk = "forwardJerk",
        .climb_rate = "climbRate",
        .vertical_acceleration = "verticalAcceleration",
        .acceleration3d = "acceleration3d",
        .jerk3d = "jerk3d",
        .altitude = "altitude",
        .course = "course",
        .turn_rate = "turnRate",
        .lateral_acceleration = "lateralAcceleration",
        .turn_radius = "turnRadius",
        .position = "position",
        .velocity_ecef = "velocityEcef",
        .acceleration_ecef = "accelerationEcef",
    });
};

pub const ValueRef = struct {
    event: usize,
    quantity: Quantity,
    side: Side = .out,
    factor: f64 = 1,
    offset: f64 = 0,
};

pub const Value = union(enum) {
    scalar: f64,
    vector: Vector,
    point: usize,
    event: ValueRef,
};

pub const Range = struct {
    min: ?Value = null,
    max: ?Value = null,
};

pub const Reduce = enum {
    mean_square,
    integral_square,

    pub const words: std.EnumArray(Reduce, []const u8) = .init(.{ .mean_square = "meanSquare", .integral_square = "integralSquare" });
};

/// An objective is made least: the key says nothing else, and nothing of it is kept.
pub const Sense = enum {
    minimize,

    pub const words = core.dictionary.tagNames(Sense);
};

pub const RuleKind = enum {
    hard,
    target,
    objective,

    pub const words = core.dictionary.tagNames(RuleKind);
};

pub const QuantityRule = struct {
    quantity: Quantity,
    comparison: union(enum) {
        eq: Value,
        range: Range,
        target: Value,
        objective: Reduce,
    },
};

pub const Relation = union(enum) {
    follow_curve: struct { curve: usize, from: f64 = 0, to: f64 = 1, tolerance: f64 = 0 },
    inside_region: usize,
};

pub const Rule = struct {
    id: []const u8,
    scope: Scope,
    scale: f64 = 1,
    weight: f64 = 1,
    definition: union(enum) {
        quantity: QuantityRule,
        relation: struct { kind: enum { hard, target }, value: Relation },
    },

    pub fn kind(self: Rule) RuleKind {
        return switch (self.definition) {
            .quantity => |q| switch (q.comparison) {
                .eq, .range => .hard,
                .target => .target,
                .objective => .objective,
            },
            .relation => |r| switch (r.kind) {
                .hard => .hard,
                .target => .target,
            },
        };
    }
};

pub const GuessState = struct {
    event: usize,
    ecef: ?Vector = null,
    velocity_ecef: ?Vector = null,
    acceleration_ecef: ?Vector = null,
};

pub const InitialGuess = struct {
    event_times: []const ?f64,
    states: []const GuessState,
};

pub const Plan = struct {
    name: []const u8,
    coordinates: Coordinates,
    geometry: Geometry,
    events: []const Event,
    sections: []const Section,
    rules: []const Rule,
    initial_guess: InitialGuess,
    /// Each event's time, as the hard rules of time decide it before any path is sought. Empty where they do not:
    /// where those rules contradict one another or put a time past what a trajectory may last, and `contradicting`
    /// then names the rules that take part; or where the times' step leaves the times to the solve.
    times: []const f64 = &.{},
    contradicting: []const usize = &.{},
};
