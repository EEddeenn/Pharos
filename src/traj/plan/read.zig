const std = @import("std");
const shared = @import("shared");
const node = shared.json.node;
const table = shared.json.table;
const Key = table.Key;
const max_duration_s = shared.trajectory.max_duration_s;
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

pub fn parseGeometry(arena: std.mem.Allocator, text: []const u8, diags: *shared.core.diagnostics.Diagnostics) Error![]const model.Place {
    const ctx: node.Ctx = .{ .arena = arena, .diags = diags };
    const tree = try node.parseTree(&ctx, text) orelse return error.InvalidInput;
    const obj = try node.root(&ctx, tree).object() orelse return error.InvalidInput;
    const raw = try table.read(RawGeometry, obj) orelse return error.InvalidInput;
    var ok = true;
    const places = try resolve.places(&ctx, raw.coordinates.altitude, raw.places, &ok);
    return if (ok) places else error.InvalidInput;
}

/// What `describe_geometry` reads: the plan's coordinates and places.
pub const RawGeometry = struct {
    coordinates: RawCoordinates = undefined,
    places: []const RawPlace = undefined,
    pub const table = [_]Key{
        .{ .name = "coordinates", .required = true, .doc = "the datum and the altitude reference of the places" },
        .{ .name = "places", .required = true, .doc = "named places" },
    };
};

pub const Raw = struct {
    format: []const u8 = undefined,
    version: u32 = undefined,
    name: []const u8 = undefined,
    coordinates: RawCoordinates = undefined,
    places: []const RawPlace = undefined,
    start: RawStart = undefined,
    segments: []const RawSegment = undefined,

    pub const table = [_]Key{
        .{ .name = "format", .required = true, .doc = "pharos.trajectory-plan" },
        .{ .name = "version", .required = true, .range = .{ .min = 1, .max = 1 }, .doc = "the plan format's version" },
        .{ .name = "name", .default = .{ .text = "" }, .doc = "the trajectory's name" },
        .{ .name = "coordinates", .required = true, .doc = "the datum and the altitude reference of the places" },
        .{ .name = "places", .required = true, .items = .{ .min = 1 }, .doc = "named places" },
        .{ .name = "start", .required = true, .doc = "where the path begins, and how" },
        .{ .name = "segments", .required = true, .items = .{ .min = 1 }, .doc = "the motion, one segment after another from the start" },
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

pub const RawPlace = struct {
    id: []const u8 = undefined,
    latitude: f64 = undefined,
    longitude: f64 = undefined,
    altitude: f64 = undefined,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "the place's name" },
        .{ .name = "latitude", .required = true, .range = .{ .min = -90, .max = 90 }, .unit = "deg", .doc = "geodetic latitude" },
        .{ .name = "longitude", .required = true, .range = .{ .min = -180, .max = 180 }, .unit = "deg", .doc = "geodetic longitude" },
        .{ .name = "altitude", .required = true, .range = .{}, .unit = "m", .doc = "height above the plan's altitude reference" },
    };
};

pub const RawStart = struct {
    at: []const u8 = undefined,
    speed: ?f64 = null,
    course: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "at", .required = true, .doc = "the place the path begins at" },
        .{ .name = "speed", .range = .{ .min = 0, .max = shared.trajectory.max_speed_mps }, .unit = "m/s", .doc = "the horizontal speed it begins with: 0 at rest; absent, the first segment's to choose" },
        .{ .name = "course", .range = .{ .min = 0, .max = 360, .open_max = true }, .unit = "deg", .doc = "the direction it begins moving in, clockwise from true north; with a speed above 0 only" },
    };
};

pub const RawSegment = struct {
    stay: ?RawStay = null,
    through: ?RawThrough = null,
    id: ?[]const u8 = null,
    @"for": ?f64 = null,
    time: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "stay", .doc = "at rest where it is" },
        .{ .name = "through", .doc = "the path of least jerk through places at stated times" },
        .{ .name = "id", .doc = "names the segment and the event at its end" },
        .{ .name = "for", .range = .{ .min = 0, .open_min = true, .max = max_duration_s }, .unit = "s", .doc = "how long a stay lasts" },
        .{ .name = "time", .range = .{ .min = 0, .max = max_duration_s }, .unit = "s", .doc = "when a stay ends, from the start" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .required = &.{ "stay", "for" }, .forbidden = &.{ "through", "time" } },
            .{ .required = &.{ "stay", "time" }, .forbidden = &.{ "through", "for" } },
            .{ .required = &.{"through"}, .forbidden = &.{ "stay", "for", "time" } },
        });
    }
};

pub const RawStay = struct {
    pub const table = [_]Key{};
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
