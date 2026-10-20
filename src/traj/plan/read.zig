const std = @import("std");
const shared = @import("shared");
const node = shared.json.node;
const Node = node.Node;
const table = shared.json.table;
const Key = table.Key;
const trajectory = shared.trajectory;
const max_duration_s = trajectory.max_duration_s;
const model = @import("model.zig");
const resolve = @import("resolve.zig");

pub const Error = shared.core.diagnostics.InputError;

pub fn parse(arena: std.mem.Allocator, text: []const u8, diags: *shared.core.diagnostics.Diagnostics) Error!model.Plan {
    const ctx: node.Ctx = .{ .arena = arena, .diags = diags };
    const tree = try node.parseTree(&ctx, text) orelse return error.InvalidInput;
    const obj = try node.root(&ctx, tree).object() orelse return error.InvalidInput;
    const raw = try table.read(Raw, obj) orelse return error.InvalidInput;
    return resolve.resolve(&ctx, raw);
}

/// The guides of a plan that may be incomplete: the plan's own keys, of which only coordinates, places and guides
/// are read, none of them needs to be complete, and each place and guide is read on its own.
pub fn parseGeometry(arena: std.mem.Allocator, text: []const u8, diags: *shared.core.diagnostics.Diagnostics) Error!resolve.Sketch {
    const ctx: node.Ctx = .{ .arena = arena, .diags = diags };
    const tree = try node.parseTree(&ctx, text) orelse return error.InvalidInput;
    const obj = try node.root(&ctx, tree).object() orelse return error.InvalidInput;
    const raw = try table.read(Partial, obj) orelse return error.InvalidInput;
    return resolve.drawn(&ctx, raw);
}

pub const Raw = struct {
    format: []const u8 = undefined,
    version: u32 = undefined,
    name: []const u8 = undefined,
    coordinates: RawCoordinates = undefined,
    places: []const RawPlace = undefined,
    guides: ?[]const RawGuide = null,
    start: RawStart = undefined,
    segments: []const RawSegment = undefined,
    limits: ?[]const RawLimit = null,

    pub const table = [_]Key{
        .{ .name = "format", .required = true, .doc = "pharos.trajectory-plan" },
        .{ .name = "version", .required = true, .range = .{ .min = 1, .max = 1 }, .doc = "the plan format's version" },
        .{ .name = "name", .default = .{ .text = "" }, .doc = "the trajectory's name" },
        .{ .name = "coordinates", .required = true, .doc = "the datum and the altitude reference of the places" },
        .{ .name = "places", .required = true, .items = .{ .min = 1 }, .doc = "named places" },
        .{ .name = "guides", .doc = "curves through places, which an along follows" },
        .{ .name = "start", .required = true, .doc = "where the path begins, and how" },
        .{ .name = "segments", .required = true, .items = .{ .min = 1 }, .doc = "the motion, one segment after another from the start" },
        .{ .name = "limits", .doc = "checks of the built path: a limit broken gives no PHT" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try s.jw.objectField("allOf");
        try s.jw.beginArray();
        try s.jw.beginObject();
        try s.begin("properties");
        try s.begin("format");
        try s.text("const", resolve.format_word);
        try s.end();
        try s.end();
        try s.jw.endObject();
        try s.jw.endArray();
    }
};

const Datum = enum {
    wgs84,
    pub const words: std.EnumArray(Datum, []const u8) = .init(.{ .wgs84 = "WGS84" });
};

pub const RawCoordinates = struct {
    datum: Datum = undefined,
    altitude: model.Altitude = undefined,
    pub const table = [_]Key{
        .{ .name = "datum", .required = true, .doc = "WGS84 geodetic coordinates" },
        .{ .name = "altitude", .required = true, .doc = "altitudes above the EGM96 geoid or the WGS84 ellipsoid" },
    };
};

const latitude_key: Key = .{ .name = "latitude", .required = true, .range = .{ .min = -90, .max = 90 }, .unit = "deg", .doc = "geodetic latitude" };
const longitude_key: Key = .{ .name = "longitude", .required = true, .range = .{ .min = -180, .max = 180 }, .unit = "deg", .doc = "geodetic longitude" };
const altitude_key: Key = .{ .name = "altitude", .required = true, .range = .{}, .unit = "m", .doc = "height above the plan's altitude reference" };

pub const RawPlace = struct {
    id: []const u8 = undefined,
    latitude: f64 = undefined,
    longitude: f64 = undefined,
    altitude: f64 = undefined,
    pub const table = [_]Key{ .{ .name = "id", .required = true, .doc = "the place's name" }, latitude_key, longitude_key, altitude_key };
};

pub const RawGuide = struct {
    id: []const u8 = undefined,
    polyline: ?RawPolyline = null,
    bezier: ?RawBezier = null,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "the guide's name" },
        .{ .name = "polyline", .doc = "straight legs from place to place, each corner rounded by an arc" },
        .{ .name = "bezier", .doc = "cubic Bezier pieces, each of four places" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .required = &.{"polyline"}, .forbidden = &.{"bezier"} },
            .{ .required = &.{"bezier"}, .forbidden = &.{"polyline"} },
        });
    }
};

const corner_key: Key = .{ .name = "radius", .required = true, .range = .{ .min = 0, .open_min = true }, .unit = "m", .doc = "the radius of the arc that rounds each corner, tangent to both its legs" };

pub const RawPolyline = struct {
    places: []const []const u8 = undefined,
    radius: f64 = undefined,
    pub const table = [_]Key{ .{ .name = "places", .required = true, .items = .{ .min = 2 }, .doc = "the places of its legs, in order" }, corner_key };
};

pub const RawBezier = struct {
    places: []const []const u8 = undefined,
    pub const table = [_]Key{
        .{ .name = "places", .required = true, .items = .{ .min = 4 }, .doc = "the places of its pieces: four for the first, three more for each after it, the last of a piece the first of the next" },
    };
};

pub const RawStart = struct {
    at: []const u8 = undefined,
    speed: ?f64 = null,
    course: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "at", .required = true, .doc = "the place the path begins at" },
        .{ .name = "speed", .range = speed_range, .unit = "m/s", .doc = "the horizontal speed over the ground it begins with: 0 at rest; absent, the first segment's to choose" },
        .{ .name = "course", .range = course_range, .unit = "deg", .doc = "the direction it begins in, clockwise from true north, where the first segment takes its direction from the start" },
    };
};

const speed_range: table.Range = .{ .min = 0, .max = trajectory.max_speed_mps };
const course_range: table.Range = .{ .min = 0, .max = 360, .open_max = true };

pub const RawSegment = struct {
    stay: ?RawStay = null,
    straight: ?RawStraight = null,
    turn: ?RawTurn = null,
    along: ?RawAlong = null,
    through: ?RawThrough = null,
    id: ?[]const u8 = null,
    @"for": ?f64 = null,
    time: ?f64 = null,
    speed: ?f64 = null,
    climb: ?f64 = null,
    altitude: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "stay", .doc = "at rest where it is" },
        .{ .name = "straight", .doc = "the shortest path over the ellipsoid, a geodesic" },
        .{ .name = "turn", .doc = "a path of constant geodesic curvature" },
        .{ .name = "along", .doc = "a guide followed" },
        .{ .name = "through", .doc = "the path of least jerk through places at stated times" },
        .{ .name = "id", .doc = "names the segment and the event at its end" },
        .{ .name = "for", .range = .{ .min = 0, .open_min = true, .max = max_duration_s }, .unit = "s", .doc = "how long the segment lasts" },
        .{ .name = "time", .range = .{ .min = 0, .max = max_duration_s }, .unit = "s", .doc = "when the segment ends, from the start" },
        .{ .name = "speed", .range = speed_range, .unit = "m/s", .doc = "the horizontal speed over the ground it ends at: 0 at rest" },
        .{ .name = "climb", .range = .{ .min = -trajectory.max_speed_mps, .max = trajectory.max_speed_mps }, .unit = "m/s", .doc = "the rate of altitude a straight or a turn ends at" },
        .{ .name = "altitude", .range = .{}, .unit = "m", .doc = "the altitude a straight or a turn ends at, in the plan's reference" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .required = &.{ "stay", "for" }, .forbidden = &.{ "straight", "turn", "along", "through", "time", "speed", "climb", "altitude" } },
            .{ .required = &.{ "stay", "time" }, .forbidden = &.{ "straight", "turn", "along", "through", "for", "speed", "climb", "altitude" } },
            .{ .required = &.{"straight"}, .forbidden = &.{ "stay", "turn", "along", "through" } },
            .{ .required = &.{"turn"}, .forbidden = &.{ "stay", "straight", "along", "through" } },
            .{ .required = &.{"along"}, .forbidden = &.{ "stay", "straight", "turn", "through", "climb", "altitude" } },
            .{ .required = &.{"through"}, .forbidden = &.{ "stay", "straight", "turn", "along", "for", "time", "speed", "climb", "altitude" } },
        });
    }
};

pub const RawStay = struct {
    pub const table = [_]Key{};
};

pub const RawStraight = struct {
    course: ?f64 = null,
    to: ?[]const u8 = null,
    distance: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "course", .range = course_range, .unit = "deg", .doc = "its initial direction, clockwise from true north: where it begins at rest, at the start or after a through" },
        .{ .name = "to", .doc = "the place it ends at, by the geodesic to it" },
        .{ .name = "distance", .range = .{ .min = 0, .open_min = true }, .unit = "m", .doc = "its length over the ground" },
    };
};

pub const RawTurn = struct {
    radius: ?f64 = null,
    rate: ?f64 = null,
    lateral: ?f64 = null,
    onto: ?f64 = null,
    by: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "radius", .range = .{}, .unit = "m", .doc = "its radius over the ground, + to the right" },
        .{ .name = "rate", .range = .{}, .unit = "deg/s", .doc = "its rate of turn at the speed it keeps, + to the right" },
        .{ .name = "lateral", .range = .{}, .unit = "m/s^2", .doc = "its lateral acceleration at the speed it keeps, + to the right" },
        .{ .name = "onto", .range = course_range, .unit = "deg", .doc = "the course it ends on, clockwise from true north" },
        .{ .name = "by", .range = .{}, .unit = "deg", .doc = "the angle it turns through, + to the right" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .required = &.{"radius"}, .forbidden = &.{ "rate", "lateral" } },
            .{ .required = &.{"rate"}, .forbidden = &.{ "radius", "lateral" } },
            .{ .required = &.{"lateral"}, .forbidden = &.{ "radius", "rate" } },
        });
    }
};

pub const RawAlong = struct {
    guide: []const u8 = undefined,
    to: ?[]const u8 = null,
    pub const table = [_]Key{
        .{ .name = "guide", .required = true, .doc = "the guide it follows, from the place where it begins" },
        .{ .name = "to", .doc = "the place of the guide it ends at; absent, the guide's end" },
    };
};

pub const RawThrough = struct {
    places: []const RawVisit = undefined,
    end: model.End = undefined,
    pub const table = [_]Key{
        .{ .name = "places", .required = true, .items = .{ .min = 1 }, .doc = "the places it passes, each at its time" },
        .{ .name = "end", .default = .{ .word = "free" }, .what = "end", .doc = "free, or at rest" },
    };
};

pub const RawVisit = struct {
    at: []const u8 = undefined,
    time: f64 = undefined,
    event: ?[]const u8 = null,
    pub const table = [_]Key{
        .{ .name = "at", .required = true, .doc = "the place" },
        .{ .name = "time", .required = true, .range = .{ .min = 0, .max = max_duration_s }, .unit = "s", .doc = "when the path is there, from the start" },
        .{ .name = "event", .doc = "the event's name, where it is not the place's: for a place passed twice" },
    };
};

pub const RawLimit = struct {
    id: ?[]const u8 = null,
    quantity: model.Quantity = undefined,
    max: ?f64 = null,
    min: ?f64 = null,
    over: ?[]const []const u8 = null,
    pub const table = [_]Key{
        .{ .name = "id", .doc = "the limit's name" },
        .{ .name = "quantity", .required = true, .doc = "what it bounds, as the path moves at its height: m/s for speeds, m/s^2 for accelerations, m/s^3 for the jerk, metres for the altitude" },
        .{ .name = "max", .range = .{}, .doc = "the most it may be; of a signed quantity (lateral, forward, climb, vertical), its size" },
        .{ .name = "min", .range = .{}, .doc = "the least it may be: of a speed or the altitude only" },
        .{ .name = "over", .items = .{ .min = 1 }, .doc = "the segments it holds over, by id; absent, every segment" },
    };
};

/// What `describe_geometry` reads: every key of a plan, and of coordinates, places and guides only what is there.
pub const Partial = struct {
    format: ?Node = null,
    version: ?Node = null,
    name: ?Node = null,
    coordinates: ?Node = null,
    places: ?[]const Node = null,
    guides: ?[]const Node = null,
    start: ?Node = null,
    segments: ?Node = null,
    limits: ?Node = null,
    pub const table = optional(Raw);
};

pub const PartialCoordinates = struct {
    datum: ?Datum = null,
    altitude: ?model.Altitude = null,
    pub const table = optional(RawCoordinates);
};

pub const PartialPlace = struct {
    id: ?[]const u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    altitude: ?f64 = null,
    pub const table = optional(RawPlace);
};

pub const PartialGuide = struct {
    id: ?[]const u8 = null,
    polyline: ?PartialPolyline = null,
    bezier: ?PartialBezier = null,
    pub const table = optional(RawGuide);
};

pub const PartialPolyline = struct {
    places: ?[]const []const u8 = null,
    radius: ?f64 = null,
    pub const table = optional(RawPolyline);
};

pub const PartialBezier = struct {
    places: ?[]const []const u8 = null,
    pub const table = optional(RawBezier);
};

/// A table's keys with none required, no default and no count of items: the keys of an object being written.
fn optional(comptime Raw_: type) [Raw_.table.len]Key {
    comptime {
        var keys = Raw_.table;
        for (&keys) |*key| {
            key.required = false;
            key.default = null;
            key.items = null;
        }
        return keys;
    }
}

const Alternative = struct {
    required: []const []const u8,
    forbidden: []const []const u8,
};

fn alternatives(s: *shared.json.schema.Schema, cases: []const Alternative) std.Io.Writer.Error!void {
    try s.jw.objectField("oneOf");
    try s.jw.beginArray();
    for (cases) |case| {
        try s.jw.beginObject();
        try s.words("required", case.required);
        try s.begin("not");
        try s.jw.objectField("anyOf");
        try s.jw.beginArray();
        for (case.forbidden) |key| {
            try s.jw.beginObject();
            try s.words("required", &.{key});
            try s.jw.endObject();
        }
        try s.jw.endArray();
        try s.end();
        try s.jw.endObject();
    }
    try s.jw.endArray();
}
