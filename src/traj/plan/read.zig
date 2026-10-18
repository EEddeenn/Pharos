const std = @import("std");
const shared = @import("shared");
const node = shared.json.node;
const table = shared.json.table;
const Key = table.Key;
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

pub fn parseGeometry(arena: std.mem.Allocator, text: []const u8, diags: *shared.core.diagnostics.Diagnostics) Error!model.Geometry {
    const ctx: node.Ctx = .{ .arena = arena, .diags = diags };
    const tree = try node.parseTree(&ctx, text) orelse return error.InvalidInput;
    const obj = try node.root(&ctx, tree).object() orelse return error.InvalidInput;
    const raw = try table.read(RawGeometryInput, obj) orelse return error.InvalidInput;
    return resolve.geometryInput(&ctx, raw);
}

pub const RawGeometryInput = struct {
    coordinates: RawCoordinates = undefined,
    geometry: RawGeometry = undefined,
    pub const table = [_]Key{
        .{ .name = "coordinates", .required = true, .doc = "the geometry datum and altitude reference" },
        .{ .name = "geometry", .required = true, .doc = "named points, guide curves and regions" },
    };
};

pub const Raw = struct {
    format: []const u8 = undefined,
    version: u32 = undefined,
    name: []const u8 = undefined,
    coordinates: RawCoordinates = undefined,
    geometry: RawGeometry = undefined,
    events: []const RawEvent = undefined,
    sections: []const RawSection = undefined,
    rules: []const RawRule = undefined,
    initial_guess: ?RawGuess = null,

    pub const table = [_]Key{
        .{ .name = "format", .required = true, .doc = "pharos.trajectory-plan" },
        .{ .name = "version", .required = true, .range = .{ .min = 1, .max = 1 }, .doc = "the trajectory plan format version" },
        .{ .name = "name", .default = .{ .text = "" }, .doc = "the trajectory name" },
        .{ .name = "coordinates", .required = true, .doc = "the geometry datum and altitude reference" },
        .{ .name = "geometry", .required = true, .doc = "named points, guide curves and regions" },
        .{ .name = "events", .required = true, .items = .{ .min = 2 }, .doc = "events in increasing time order; the first is at zero" },
        .{ .name = "sections", .required = true, .items = .{ .min = 1 }, .doc = "the ordered chain joining consecutive events" },
        .{ .name = "rules", .required = true, .doc = "hard constraints, soft targets and objectives" },
        .{ .name = "initialGuess", .doc = "optional solver starting values; not constraints" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try s.jw.objectField("allOf");
        try s.jw.beginArray();
        try s.jw.beginObject();
        try s.begin("properties");
        try s.begin("format");
        try s.text("const", "pharos.trajectory-plan");
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
        .{ .name = "altitude", .required = true, .doc = "EGM96 geoid or WGS84 ellipsoid altitude" },
    };
};

pub const RawPosition = struct {
    latitude: f64 = undefined,
    longitude: f64 = undefined,
    altitude: f64 = undefined,
    pub const table = [_]Key{
        .{ .name = "latitude", .required = true, .range = .{ .min = -90, .max = 90 }, .unit = "deg", .doc = "geodetic latitude" },
        .{ .name = "longitude", .required = true, .range = .{ .min = -180, .max = 180 }, .unit = "deg", .doc = "geodetic longitude" },
        .{ .name = "altitude", .required = true, .range = .{}, .unit = "m", .doc = "height in the plan's altitude reference" },
    };

    pub fn position(self: RawPosition) model.Position {
        return .{ .latitude = self.latitude, .longitude = self.longitude, .altitude = self.altitude };
    }
};

pub const RawPoint = struct {
    id: []const u8 = undefined,
    position: RawPosition = undefined,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "stable point identifier" },
        .{ .name = "position", .required = true, .doc = "geodetic point position" },
    };
};

pub const RawCurve = struct {
    id: []const u8 = undefined,
    type: model.CurveKind = undefined,
    points: []const []const u8 = undefined,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "stable curve identifier" },
        .{ .name = "type", .required = true, .doc = "piecewise cubic ECEF Bezier or polyline" },
        .{ .name = "points", .required = true, .items = .{ .min = 2 }, .doc = "point identifiers; Bezier chains require 3n+1 points" },
    };
};

pub const RegionKind = enum {
    circle,
    polygon,
    pub const words = shared.core.dictionary.tagNames(RegionKind);
};

pub const RawRegion = struct {
    id: []const u8 = undefined,
    type: RegionKind = undefined,
    center: ?[]const u8 = null,
    radius: ?f64 = null,
    points: ?[]const []const u8 = null,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "stable region identifier" },
        .{ .name = "type", .required = true, .doc = "circle or convex polygon in a local ENU frame" },
        .{ .name = "center", .doc = "circle center point identifier" },
        .{ .name = "radius", .range = .{ .min = 0, .open_min = true }, .unit = "m", .doc = "circle radius" },
        .{ .name = "points", .items = .{ .min = 3 }, .doc = "convex polygon boundary point identifiers in order" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .tag = .{ .key = "type", .value = "circle" }, .required = &.{ "center", "radius" }, .forbidden = &.{"points"} },
            .{ .tag = .{ .key = "type", .value = "polygon" }, .required = &.{"points"}, .forbidden = &.{ "center", "radius" } },
        });
    }
};

pub const RawGeometry = struct {
    points: []const RawPoint = undefined,
    curves: ?[]const RawCurve = null,
    regions: ?[]const RawRegion = null,
    pub const table = [_]Key{
        .{ .name = "points", .required = true, .doc = "geometry points" },
        .{ .name = "curves", .doc = "guide curves" },
        .{ .name = "regions", .doc = "allowed regions" },
    };
};

pub const RawEvent = struct {
    id: []const u8 = undefined,
    continuity: model.Continuity = undefined,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "stable event identifier" },
        .{ .name = "continuity", .default = .{ .word = "C2" }, .doc = "position, position/velocity, or position/velocity/acceleration continuity" },
    };
};

pub const RawSection = struct {
    id: []const u8 = undefined,
    from: []const u8 = undefined,
    to: []const u8 = undefined,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "stable section identifier" },
        .{ .name = "from", .required = true, .doc = "starting event identifier" },
        .{ .name = "to", .required = true, .doc = "ending event identifier" },
    };
};

pub const RawScope = struct {
    event: ?[]const u8 = null,
    side: ?model.Side = null,
    section: ?[]const u8 = null,
    between: ?[]const []const u8 = null,
    time: ?f64 = null,
    time_range: ?[]const f64 = null,
    all: ?bool = null,
    pub const table = [_]Key{
        .{ .name = "event", .doc = "event identifier" },
        .{ .name = "side", .doc = "incoming or outgoing event state; default outgoing" },
        .{ .name = "section", .doc = "section identifier" },
        .{ .name = "between", .items = .{ .min = 2, .max = 2 }, .doc = "ordered bounding event identifiers" },
        .{ .name = "time", .range = .{ .min = 0, .max = shared.trajectory.max_duration_s }, .unit = "s", .doc = "fixed elapsed time" },
        .{ .name = "timeRange", .range = .{ .min = 0, .max = shared.trajectory.max_duration_s }, .items = .{ .min = 2, .max = 2 }, .unit = "s", .doc = "increasing fixed elapsed-time bounds" },
        .{ .name = "all", .doc = "true selects the whole trajectory" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .required = &.{"event"}, .forbidden = &.{ "section", "between", "time", "timeRange", "all" } },
            .{ .required = &.{"section"}, .forbidden = &.{ "event", "side", "between", "time", "timeRange", "all" } },
            .{ .required = &.{"between"}, .forbidden = &.{ "event", "side", "section", "time", "timeRange", "all" } },
            .{ .required = &.{"time"}, .forbidden = &.{ "event", "side", "section", "between", "timeRange", "all" } },
            .{ .required = &.{"timeRange"}, .forbidden = &.{ "event", "side", "section", "between", "time", "all" } },
            .{ .required = &.{"all"}, .forbidden = &.{ "event", "side", "section", "between", "time", "timeRange" } },
        });
        try s.jw.objectField("allOf");
        try s.jw.beginArray();
        try s.jw.beginObject();
        try s.begin("properties");
        try s.begin("all");
        try s.jw.objectField("const");
        try s.jw.write(true);
        try s.end();
        try s.end();
        try s.jw.endObject();
        try s.jw.endArray();
    }
};

pub const RawValue = struct {
    node: node.Node,
    pub fn fromJson(n: node.Node) node.Error!?RawValue {
        return .{ .node = n };
    }
    pub fn schema(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try s.jw.objectField("anyOf");
        try s.jw.beginArray();
        try s.jw.beginObject();
        try s.text("type", "number");
        try s.jw.endObject();
        try s.jw.beginObject();
        try vectorSchema(s);
        try s.jw.endObject();
        try s.jw.beginObject();
        try s.text("type", "object");
        try s.begin("properties");
        try s.begin("point");
        try s.text("type", "string");
        try s.end();
        try s.end();
        try s.words("required", &.{"point"});
        try s.jw.objectField("additionalProperties");
        try s.jw.write(false);
        try s.jw.endObject();
        try s.jw.beginObject();
        try s.text("type", "object");
        try s.begin("properties");
        try s.begin("event");
        try s.text("type", "string");
        try s.end();
        try s.begin("quantity");
        try s.text("type", "string");
        try s.words("enum", &model.Quantity.words.values);
        try s.end();
        try s.begin("side");
        try s.text("type", "string");
        try s.words("enum", &model.Side.words.values);
        try s.end();
        inline for (.{ "factor", "offset" }) |key| {
            try s.begin(key);
            try s.text("type", "number");
            try s.end();
        }
        try s.end();
        try s.words("required", &.{ "event", "quantity" });
        try s.jw.objectField("additionalProperties");
        try s.jw.write(false);
        try s.jw.endObject();
        try s.jw.endArray();
    }
};

pub const RawVector = struct {
    value: model.Vector,
    pub fn fromJson(n: node.Node) node.Error!?RawVector {
        const items = try n.array() orelse return null;
        if (items.len != 3) {
            try n.ctx.diags.err(.out_of_range, n.path, "a vector must contain exactly three components", .{});
            return null;
        }
        var a: [3]f64 = undefined;
        var ok = true;
        for (items, 0..) |item, i| {
            const v = try n.item(i, item);
            a[i] = try v.number() orelse {
                ok = false;
                continue;
            };
            if (!std.math.isFinite(a[i])) {
                try n.ctx.diags.err(.out_of_range, v.path, "a vector component must be finite", .{});
                ok = false;
            }
        }
        return if (ok) .{ .value = .fromArray(a) } else null;
    }
    pub fn schema(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try vectorSchema(s);
    }
};

fn vectorSchema(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
    try s.text("type", "array");
    inline for (.{ "minItems", "maxItems" }) |key| {
        try s.jw.objectField(key);
        try s.jw.write(@as(u32, 3));
    }
    try s.begin("items");
    try s.text("type", "number");
    try s.end();
}

pub const RawRange = struct {
    min: ?RawValue = null,
    max: ?RawValue = null,
    pub const table = [_]Key{
        .{ .name = "min", .doc = "inclusive lower bound" },
        .{ .name = "max", .doc = "inclusive upper bound" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try s.jw.objectField("anyOf");
        try s.jw.beginArray();
        inline for (.{ "min", "max" }) |key| {
            try s.jw.beginObject();
            try s.words("required", &.{key});
            try s.jw.endObject();
        }
        try s.jw.endArray();
    }
};

pub const RelationKind = enum {
    follow_curve,
    inside_region,
    pub const words: std.EnumArray(RelationKind, []const u8) = .init(.{ .follow_curve = "followCurve", .inside_region = "insideRegion" });
};

pub const RawRelation = struct {
    type: RelationKind = undefined,
    curve: ?[]const u8 = null,
    from: ?f64 = null,
    to: ?f64 = null,
    tolerance: ?f64 = null,
    region: ?[]const u8 = null,
    pub const table = [_]Key{
        .{ .name = "type", .required = true, .doc = "geometric relation" },
        .{ .name = "curve", .doc = "guide curve identifier" },
        .{ .name = "from", .range = .{ .min = 0, .max = 1 }, .doc = "initial curve parameter; default zero" },
        .{ .name = "to", .range = .{ .min = 0, .max = 1 }, .doc = "final curve parameter; default one" },
        .{ .name = "tolerance", .range = .{ .min = 0 }, .unit = "m", .doc = "allowed distance from the curve; default zero" },
        .{ .name = "region", .doc = "region identifier" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .tag = .{ .key = "type", .value = "followCurve" }, .required = &.{"curve"}, .forbidden = &.{"region"} },
            .{ .tag = .{ .key = "type", .value = "insideRegion" }, .required = &.{"region"}, .forbidden = &.{ "curve", "from", "to", "tolerance" } },
        });
    }
};

pub const RawRule = struct {
    id: []const u8 = undefined,
    kind: model.RuleKind = undefined,
    scope: RawScope = undefined,
    quantity: ?model.Quantity = null,
    eq: ?RawValue = null,
    range: ?RawRange = null,
    value: ?RawValue = null,
    scale: f64 = undefined,
    weight: f64 = undefined,
    reduce: ?model.Reduce = null,
    sense: ?model.Sense = null,
    relation: ?RawRelation = null,
    pub const table = [_]Key{
        .{ .name = "id", .required = true, .doc = "stable rule identifier" },
        .{ .name = "kind", .required = true, .doc = "hard constraint, target or objective" },
        .{ .name = "scope", .required = true, .doc = "where the rule applies" },
        .{ .name = "quantity", .doc = "physical quantity to constrain or optimize; forwardSpeed is the horizontal speed, along the path's own course and never negative" },
        .{ .name = "eq", .doc = "hard equality value" },
        .{ .name = "range", .doc = "hard inclusive bounds; at least one bound is required" },
        .{ .name = "value", .doc = "soft target value" },
        .{ .name = "scale", .default = .{ .number = 1 }, .range = .{ .min = 0, .open_min = true }, .doc = "positive physical normalization scale" },
        .{ .name = "weight", .default = .{ .number = 1 }, .range = .{ .min = 0, .open_min = true }, .doc = "positive target or objective weight" },
        .{ .name = "reduce", .doc = "objective reduction; default value" },
        .{ .name = "sense", .doc = "objective direction; default minimize" },
        .{ .name = "relation", .doc = "geometric relation instead of a quantity" },
    };

    pub fn schemaMetadata(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try alternatives(s, &.{
            .{ .tag = .{ .key = "kind", .value = "hard" }, .required = &.{ "quantity", "eq" }, .forbidden = &.{ "range", "value", "relation", "reduce", "sense" } },
            .{ .tag = .{ .key = "kind", .value = "hard" }, .required = &.{ "quantity", "range" }, .forbidden = &.{ "eq", "value", "relation", "reduce", "sense" } },
            .{ .tag = .{ .key = "kind", .value = "hard" }, .required = &.{"relation"}, .forbidden = &.{ "quantity", "eq", "range", "value", "reduce", "sense" } },
            .{ .tag = .{ .key = "kind", .value = "target" }, .required = &.{ "quantity", "value" }, .forbidden = &.{ "eq", "range", "relation", "reduce", "sense" } },
            .{ .tag = .{ .key = "kind", .value = "target" }, .required = &.{"relation"}, .forbidden = &.{ "quantity", "eq", "range", "value", "reduce", "sense" } },
            .{ .tag = .{ .key = "kind", .value = "objective" }, .required = &.{"quantity"}, .forbidden = &.{ "eq", "range", "value", "relation" } },
        });
    }
};

const Alternative = struct {
    tag: ?struct { key: []const u8, value: []const u8 } = null,
    required: []const []const u8,
    forbidden: []const []const u8,
};

fn alternatives(s: *shared.json.schema.Schema, cases: []const Alternative) std.Io.Writer.Error!void {
    try s.jw.objectField("oneOf");
    try s.jw.beginArray();
    for (cases) |case| {
        try s.jw.beginObject();
        if (case.tag) |tag| {
            try s.begin("properties");
            try s.begin(tag.key);
            try s.text("const", tag.value);
            try s.end();
            try s.end();
        }
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

pub const TimeEntry = struct { id: []const u8, value: f64 };
pub const RawTimes = struct {
    entries: []const TimeEntry,
    pub fn fromJson(n: node.Node) node.Error!?RawTimes {
        const obj = try n.object() orelse return null;
        const out = try n.ctx.arena.alloc(TimeEntry, obj.keys().len);
        var ok = true;
        for (obj.keys(), 0..) |id, i| {
            const value = try obj.entry(i);
            const v = try value.number() orelse {
                ok = false;
                continue;
            };
            if (!std.math.isFinite(v) or v < 0 or v > shared.trajectory.max_duration_s) {
                try n.ctx.diags.err(.out_of_range, value.path, "an event time must be in [0, {d}] seconds", .{shared.trajectory.max_duration_s});
                ok = false;
            }
            out[i] = .{ .id = id, .value = v };
        }
        return if (ok) .{ .entries = out } else null;
    }
    pub fn schema(s: *shared.json.schema.Schema) std.Io.Writer.Error!void {
        try s.text("type", "object");
        try s.begin("additionalProperties");
        try s.text("type", "number");
        try s.jw.objectField("minimum");
        try s.jw.write(@as(u32, 0));
        try s.jw.objectField("maximum");
        try s.jw.write(shared.trajectory.max_duration_s);
        try s.end();
    }
};

pub const RawGuessState = struct {
    event: []const u8 = undefined,
    position: ?RawPosition = null,
    velocity_ecef: ?RawVector = null,
    acceleration_ecef: ?RawVector = null,
    pub const table = [_]Key{
        .{ .name = "event", .required = true, .doc = "event identifier" },
        .{ .name = "position", .doc = "initial position" },
        .{ .name = "velocityEcef", .unit = "m/s", .doc = "initial ECEF velocity" },
        .{ .name = "accelerationEcef", .unit = "m/s^2", .doc = "initial ECEF acceleration" },
    };
};

pub const RawGuess = struct {
    event_times: ?RawTimes = null,
    states: ?[]const RawGuessState = null,
    pub const table = [_]Key{
        .{ .name = "eventTimes", .doc = "initial times indexed by event identifier" },
        .{ .name = "states", .doc = "initial event states" },
    };
};
