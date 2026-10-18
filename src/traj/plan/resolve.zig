const std = @import("std");
const shared = @import("shared");
const node = shared.json.node;
const table = shared.json.table;
const Key = table.Key;
const model = @import("model.zig");
const read = @import("read.zig");
const geometry = @import("geometry.zig");
const quantities = @import("quantities.zig");
const Error = shared.core.diagnostics.InputError;
const Ids = std.StringHashMapUnmanaged(usize);

const Context = struct {
    ctx: *const node.Ctx,
    points: Ids,
    curves: Ids,
    regions: Ids,
    events: Ids,
    sections: Ids,

    fn index(self: Context, ids: Ids, id: []const u8, path: []const u8) Error!usize {
        return ids.get(id) orelse return fail(self.ctx, .unknown_name, path, "unknown identifier \"{s}\"", .{id});
    }
};

fn fail(ctx: *const node.Ctx, code: shared.core.diagnostics.Code, path: []const u8, comptime fmt: []const u8, args: anytype) Error {
    ctx.diags.err(code, path, fmt, args) catch return error.OutOfMemory;
    return error.InvalidInput;
}

fn names(ctx: *const node.Ctx, entries: anytype, path: []const u8) Error!Ids {
    var result: Ids = .empty;
    for (entries, 0..) |entry, i| {
        const location = try node.join(ctx, try node.element(ctx, path, i), "id");
        if (std.mem.trim(u8, entry.id, " \t\r\n").len == 0) return fail(ctx, .out_of_range, location, "an identifier must not be empty", .{});
        const found = try result.getOrPut(ctx.arena, entry.id);
        if (found.found_existing) return fail(ctx, .duplicate, location, "identifier \"{s}\" is already used by {s}[{d}]", .{ entry.id, path, found.value_ptr.* });
        found.value_ptr.* = i;
    }
    return result;
}

pub fn resolve(ctx: *const node.Ctx, raw: read.Raw) Error!model.Plan {
    if (!std.mem.eql(u8, raw.format, "pharos.trajectory-plan")) return fail(ctx, .invalid_format, "format", "expected pharos.trajectory-plan", .{});
    var c = try geometryContext(ctx, raw.geometry);
    c.events = try names(ctx, raw.events, "events");
    c.sections = try names(ctx, raw.sections, "sections");
    _ = try names(ctx, raw.rules, "rules");
    const resolved_geometry = try resolveGeometry(c, raw.geometry, raw.coordinates.altitude);
    const events = try ctx.arena.alloc(model.Event, raw.events.len);
    for (raw.events, events) |given, *out| out.* = .{ .id = given.id, .continuity = given.continuity };
    if (raw.sections.len != events.len - 1) return fail(ctx, .out_of_range, "sections", "the chain needs exactly one section between every consecutive pair of events", .{});
    const sections = try ctx.arena.alloc(model.Section, raw.sections.len);
    for (raw.sections, sections, 0..) |given, *out, i| {
        const path = try node.element(ctx, "sections", i);
        const from = try c.index(c.events, given.from, try node.join(ctx, path, "from"));
        const to = try c.index(c.events, given.to, try node.join(ctx, path, "to"));
        if (from != i or to != i + 1) return fail(ctx, .out_of_range, path, "section {d} must join events[{d}] to events[{d}] in authored order", .{ i, i, i + 1 });
        out.* = .{ .id = given.id };
    }
    const rules = try ctx.arena.alloc(model.Rule, raw.rules.len);
    for (raw.rules, rules, 0..) |given, *out, i| out.* = try rule(c, given, try node.element(ctx, "rules", i));
    try directions(ctx, events, rules);
    return .{
        .name = raw.name,
        .coordinates = .{ .altitude = raw.coordinates.altitude },
        .geometry = resolved_geometry,
        .events = events,
        .sections = sections,
        .rules = rules,
        .initial_guess = try guess(c, raw.initial_guess, raw.coordinates.altitude, events.len),
    };
}

fn geometryContext(ctx: *const node.Ctx, raw: read.RawGeometry) Error!Context {
    return .{
        .ctx = ctx,
        .points = try names(ctx, raw.points, "geometry.points"),
        .curves = try names(ctx, raw.curves orelse &.{}, "geometry.curves"),
        .regions = try names(ctx, raw.regions orelse &.{}, "geometry.regions"),
        .events = .empty,
        .sections = .empty,
    };
}

pub fn geometryInput(ctx: *const node.Ctx, raw: read.RawGeometryInput) Error!model.Geometry {
    return resolveGeometry(try geometryContext(ctx, raw.geometry), raw.geometry, raw.coordinates.altitude);
}

fn resolveGeometry(c: Context, raw: read.RawGeometry, altitude: model.Altitude) Error!model.Geometry {
    const ctx = c.ctx;
    const raw_curves = raw.curves orelse &.{};
    const raw_regions = raw.regions orelse &.{};
    const points = try ctx.arena.alloc(model.Point, raw.points.len);
    for (raw.points, points, 0..) |given, *out, i| {
        const p = given.position.position();
        const ecef = geometry.toEcef(p, altitude);
        if (!shared.trajectory.positionInRange(ecef)) return fail(ctx, .out_of_range, try node.join(ctx, try node.element(ctx, "geometry.points", i), "position"), "position lies outside the trajectory geocentre-radius domain", .{});
        out.* = .{ .id = given.id, .ecef = ecef };
    }
    const curves = try ctx.arena.alloc(model.Curve, raw_curves.len);
    for (raw_curves, curves, 0..) |given, *out, i| {
        const path = try node.element(ctx, "geometry.curves", i);
        if (given.type == .bezier and (given.points.len < 4 or (given.points.len - 1) % 3 != 0)) return fail(ctx, .out_of_range, try node.join(ctx, path, "points"), "a Bezier chain requires 3n+1 points for n >= 1", .{});
        out.* = .{ .id = given.id, .kind = given.type, .points = try pointIndices(c, given.points, try node.join(ctx, path, "points")) };
    }
    const regions = try ctx.arena.alloc(model.Region, raw_regions.len);
    for (raw_regions, regions, 0..) |given, *out, i| {
        const path = try node.element(ctx, "geometry.regions", i);
        out.* = .{ .id = given.id, .shape = switch (given.type) {
            .circle => blk: {
                if (given.points != null) return fail(ctx, .out_of_range, path, "a circle takes center and radius, not points", .{});
                const center = given.center orelse return fail(ctx, .missing_field, try node.join(ctx, path, "center"), "required for a circle", .{});
                const radius = given.radius orelse return fail(ctx, .missing_field, try node.join(ctx, path, "radius"), "required for a circle", .{});
                break :blk .{ .circle = .{ .center = try c.index(c.points, center, try node.join(ctx, path, "center")), .radius = radius } };
            },
            .polygon => blk: {
                if (given.center != null or given.radius != null) return fail(ctx, .out_of_range, path, "a polygon takes points, not center or radius", .{});
                const references = given.points orelse return fail(ctx, .missing_field, try node.join(ctx, path, "points"), "required for a polygon", .{});
                const indices = try pointIndices(c, references, try node.join(ctx, path, "points"));
                if (!geometry.polygonValid(points, indices)) return fail(ctx, .out_of_range, try node.join(ctx, path, "points"), "polygon points must form a nondegenerate convex boundary in their local ENU frame", .{});
                break :blk .{ .polygon = indices };
            },
        } };
    }
    return .{ .points = points, .curves = curves, .regions = regions };
}

fn pointIndices(c: Context, references: []const []const u8, path: []const u8) Error![]const usize {
    const out = try c.ctx.arena.alloc(usize, references.len);
    for (references, out, 0..) |id, *index, i| index.* = try c.index(c.points, id, try node.element(c.ctx, path, i));
    return out;
}

fn scope(c: Context, raw: read.RawScope, path: []const u8) Error!model.Scope {
    const count = @as(u8, @intFromBool(raw.event != null)) + @intFromBool(raw.section != null) + @intFromBool(raw.between != null) + @intFromBool(raw.time != null) + @intFromBool(raw.time_range != null) + @intFromBool(raw.all != null);
    if (count != 1) return fail(c.ctx, .out_of_range, path, "a scope selects exactly one of event, section, between, time, timeRange or all", .{});
    if (raw.side != null and raw.event == null) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "side"), "side is only valid for an event scope", .{});
    if (raw.event) |id| return .{ .event = .{ .index = try c.index(c.events, id, try node.join(c.ctx, path, "event")), .side = raw.side orelse .out } };
    if (raw.section) |id| return .{ .section = try c.index(c.sections, id, try node.join(c.ctx, path, "section")) };
    if (raw.between) |ids| {
        const a = try c.index(c.events, ids[0], try node.element(c.ctx, try node.join(c.ctx, path, "between"), 0));
        const b = try c.index(c.events, ids[1], try node.element(c.ctx, try node.join(c.ctx, path, "between"), 1));
        if (a >= b) return fail(c.ctx, .out_of_range, path, "between requires two different events in chronological order", .{});
        return .{ .between = .{ a, b } };
    }
    if (raw.time) |t| return .{ .time = t };
    if (raw.time_range) |bounds| {
        if (bounds[0] >= bounds[1]) return fail(c.ctx, .out_of_range, path, "timeRange requires increasing bounds", .{});
        return .{ .time_range = .{ bounds[0], bounds[1] } };
    }
    if (!raw.all.?) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "all"), "all must be true", .{});
    return .all;
}

const RawReference = struct {
    point: ?[]const u8 = null,
    event: ?[]const u8 = null,
    quantity: ?model.Quantity = null,
    side: ?model.Side = null,
    factor: ?f64 = null,
    offset: ?f64 = null,
    pub const table = [_]Key{
        .{ .name = "point", .doc = "point reference" },
        .{ .name = "event", .doc = "event reference" },
        .{ .name = "quantity", .doc = "referenced quantity" },
        .{ .name = "side", .doc = "referenced event side" },
        .{ .name = "factor", .range = .{}, .doc = "reference multiplier" },
        .{ .name = "offset", .range = .{}, .doc = "reference offset" },
    };
};

fn value(c: Context, raw: read.RawValue, quantity: model.Quantity) Error!model.Value {
    const n = raw.node;
    switch (n.value) {
        .integer, .float, .number_string => {
            if (quantities.components(quantity) != 1) return fail(c.ctx, .wrong_type, n.path, "{s} requires a three-component value", .{model.Quantity.words.get(quantity)});
            const number = try n.number() orelse return error.InvalidInput;
            if (!std.math.isFinite(number)) return fail(c.ctx, .out_of_range, n.path, "a rule value must be finite", .{});
            return .{ .scalar = number };
        },
        .array => {
            if (quantities.components(quantity) != 3) return fail(c.ctx, .wrong_type, n.path, "{s} requires a scalar value", .{model.Quantity.words.get(quantity)});
            const vector = try read.RawVector.fromJson(n) orelse return error.InvalidInput;
            if (quantity == .position and !shared.trajectory.positionInRange(vector.value)) return fail(c.ctx, .out_of_range, n.path, "position lies outside the trajectory geocentre-radius domain", .{});
            return .{ .vector = vector.value };
        },
        .object => {
            const obj = try n.object() orelse unreachable;
            const reference = try table.read(RawReference, obj) orelse return error.InvalidInput;
            for (obj.keys()) |key| {
                const known = for (RawReference.table) |entry| {
                    if (std.mem.eql(u8, key, entry.name)) break true;
                } else false;
                if (!known) return fail(c.ctx, .unknown_key, try obj.childPath(key), "unknown reference field", .{});
            }
            if (reference.point) |id| {
                if (quantity != .position) return fail(c.ctx, .wrong_type, n.path, "a point reference is only valid for position", .{});
                if (reference.event != null or reference.quantity != null or reference.side != null or reference.factor != null or reference.offset != null) return fail(c.ctx, .out_of_range, n.path, "a point reference takes only point", .{});
                return .{ .point = try c.index(c.points, id, try obj.childPath("point")) };
            }
            const event = reference.event orelse return fail(c.ctx, .missing_field, n.path, "a reference requires point or event", .{});
            const q = reference.quantity orelse return fail(c.ctx, .missing_field, try obj.childPath("quantity"), "an event reference requires quantity", .{});
            if (q == .duration) return fail(c.ctx, .out_of_range, try obj.childPath("quantity"), "duration is not defined at one event", .{});
            if (!quantities.compatible(quantity, q)) return fail(c.ctx, .wrong_type, try obj.childPath("quantity"), "{s} and {s} have different dimensions or component counts", .{ model.Quantity.words.get(quantity), model.Quantity.words.get(q) });
            const index = try c.index(c.events, event, try obj.childPath("event"));
            const factor = reference.factor orelse 1;
            const offset = reference.offset orelse 0;
            // A value that refers with a factor of zero is its offset: a number.
            if (factor == 0) return if (quantities.components(quantity) == 3) .{ .vector = .{ .x = offset, .y = offset, .z = offset } } else .{ .scalar = offset };
            return .{ .event = .{ .event = index, .quantity = if (q == .forward_speed) .horizontal_speed else q, .side = reference.side orelse .out, .factor = factor, .offset = offset } };
        },
        else => return fail(c.ctx, .wrong_type, n.path, "expected a number, three-component vector, point reference or event reference", .{}),
    }
}

fn ordered(a: model.Value, b: model.Value) bool {
    if (a == .scalar and b == .scalar) return a.scalar <= b.scalar;
    if (a == .vector and b == .vector) {
        const lo = a.vector.toArray();
        const hi = b.vector.toArray();
        for (lo, hi) |x, y| if (x > y) return false;
    }
    return true;
}

fn rule(c: Context, raw: read.RawRule, path: []const u8) Error!model.Rule {
    const selected = try scope(c, raw.scope, try node.join(c.ctx, path, "scope"));
    var out: model.Rule = .{ .id = raw.id, .scope = selected, .scale = raw.scale, .weight = raw.weight, .definition = undefined };
    if (raw.relation) |relation| {
        const invalid = "a relation rule is hard or target and takes no quantity, comparison, reduction or sense";
        if (raw.quantity != null or raw.eq != null or raw.range != null or raw.value != null or raw.reduce != null or raw.sense != null) return fail(c.ctx, .out_of_range, path, invalid, .{});
        out.definition = .{ .relation = .{ .kind = switch (raw.kind) {
            .hard => .hard,
            .target => .target,
            .objective => return fail(c.ctx, .out_of_range, path, invalid, .{}),
        }, .value = switch (relation.type) {
            .follow_curve => blk: {
                if (relation.region != null) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "relation"), "followCurve takes no region", .{});
                const id = relation.curve orelse return fail(c.ctx, .missing_field, try node.join(c.ctx, path, "relation.curve"), "required for followCurve", .{});
                const from = relation.from orelse 0;
                const to = relation.to orelse 1;
                break :blk .{ .follow_curve = .{ .curve = try c.index(c.curves, id, try node.join(c.ctx, path, "relation.curve")), .from = from, .to = to, .tolerance = relation.tolerance orelse 0 } };
            },
            .inside_region => blk: {
                if (relation.curve != null or relation.from != null or relation.to != null or relation.tolerance != null) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "relation"), "insideRegion takes only type and region", .{});
                const id = relation.region orelse return fail(c.ctx, .missing_field, try node.join(c.ctx, path, "relation.region"), "required for insideRegion", .{});
                break :blk .{ .inside_region = try c.index(c.regions, id, try node.join(c.ctx, path, "relation.region")) };
            },
        } } };
        return out;
    }
    const quantity = raw.quantity orelse return fail(c.ctx, .missing_field, try node.join(c.ctx, path, "quantity"), "a rule requires quantity or relation", .{});
    if (!quantities.scopeAllowed(quantity, selected)) return fail(c.ctx, .out_of_range, path, "{s} requires {s} scope", .{ model.Quantity.words.get(quantity), if (quantity == .time) "an event" else "an interval" });
    var q: model.QuantityRule = .{ .quantity = quantity, .comparison = undefined };
    switch (raw.kind) {
        .hard => {
            if ((raw.eq == null) == (raw.range == null) or raw.value != null or raw.reduce != null or raw.sense != null) return fail(c.ctx, .out_of_range, path, "a hard quantity rule takes exactly one of eq or range", .{});
            if (raw.eq) |given| q.comparison = .{ .eq = try value(c, given, quantity) } else {
                const given = raw.range.?;
                if (given.min == null and given.max == null) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "range"), "a range requires min or max", .{});
                const bounds: model.Range = .{ .min = if (given.min) |v| try value(c, v, quantity) else null, .max = if (given.max) |v| try value(c, v, quantity) else null };
                if (bounds.min != null and bounds.max != null and !ordered(bounds.min.?, bounds.max.?)) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "range"), "range min must not exceed max", .{});
                q.comparison = .{ .range = bounds };
            }
        },
        .target => {
            if (raw.eq != null or raw.range != null or raw.reduce != null or raw.sense != null) return fail(c.ctx, .out_of_range, path, "a target quantity rule takes value, scale and weight", .{});
            const given = raw.value orelse return fail(c.ctx, .missing_field, try node.join(c.ctx, path, "value"), "required for a target", .{});
            q.comparison = .{ .target = try value(c, given, quantity) };
        },
        .objective => {
            if (raw.eq != null or raw.range != null or raw.value != null) return fail(c.ctx, .out_of_range, path, "an objective takes reduce and sense instead of a comparison", .{});
            const reduction = raw.reduce orelse .value;
            if (!quantities.interval(selected) and reduction == .integral_square) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "reduce"), "integralSquare requires an interval scope", .{});
            if (quantities.components(quantity) == 3 and reduction == .value) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "reduce"), "a vector objective requires meanSquare or integralSquare", .{});
            q.comparison = .{ .objective = .{ .reduce = reduction, .sense = raw.sense orelse .minimize } };
        },
    }
    // Directions are the path's own: the speed along the course is the horizontal speed, and is never negative.
    if (quantity == .forward_speed) {
        const most: ?model.Value = switch (q.comparison) {
            .eq, .target => |v| v,
            .range => |range| range.max,
            .objective => null,
        };
        if (most) |v| if (v == .scalar and v.scalar < 0) return fail(c.ctx, .out_of_range, path, "forwardSpeed below zero is reverse motion, which is not supported: the course is the path's own", .{});
        q.quantity = .horizontal_speed;
    }
    out.definition = .{ .quantity = q };
    return out;
}

/// Whether a rule holds the speed at zero wherever it applies.
fn rests(given: model.Rule) bool {
    if (given.definition != .quantity) return false;
    const q = given.definition.quantity;
    const most: model.Value = switch (q.comparison) {
        .eq => |v| v,
        .range => |range| range.max orelse return false,
        .target, .objective => return false,
    };
    return switch (q.quantity) {
        .speed3d, .horizontal_speed => most == .scalar and most.scalar == 0,
        .velocity_ecef => q.comparison == .eq and most == .vector and most.vector.x == 0 and most.vector.y == 0 and most.vector.z == 0,
        .position => q.comparison == .eq and most != .event and quantities.interval(given.scope),
        else => false,
    };
}

/// Whether some rule holds the speed at zero from one fixed time to another.
fn restsBetween(rules: []const model.Rule, from: f64, to: f64) bool {
    for (rules) |given| {
        if (!rests(given)) continue;
        const held: [2]f64 = switch (given.scope) {
            .time => |time| .{ time, time },
            .time_range => |range| range,
            else => continue,
        };
        if (held[0] <= from and to <= held[1]) return true;
    }
    return false;
}

/// A direction of travel has no value where the path is at rest. Where the plan's own rules hold the speed at zero,
/// an equality, a target or an objective at that very event or time, and an equality over the whole of such a
/// stretch, ask for what is not there: they are refused. A limit holds there, whatever its value, and so does a
/// soft rule over such a stretch, and any rule over a journey that only sets out from rest or comes to rest.
fn directions(ctx: *const node.Ctx, events: []const model.Event, rules: []const model.Rule) Error!void {
    const in = try ctx.arena.alloc(bool, events.len);
    const out = try ctx.arena.alloc(bool, events.len);
    const sections = try ctx.arena.alloc(bool, events.len - 1);
    @memset(in, false);
    @memset(out, false);
    @memset(sections, false);
    for (rules) |given| if (rests(given)) switch (given.scope) {
        .event => |event| (if (event.side == .in) in else out)[event.index] = true,
        .section => |index| sections[index] = true,
        .between => |ends| @memset(sections[ends[0]..ends[1]], true),
        .all => @memset(sections, true),
        .time, .time_range => {},
    };
    for (sections, 0..) |rest, i| if (rest) {
        out[i] = true;
        in[i + 1] = true;
    };
    for (events, in, out, 0..) |event, *before, *after, i| if (i == 0 or i + 1 == events.len or event.continuity != .c0) {
        before.* = before.* or after.*;
        after.* = before.*;
    };
    const whole = std.mem.allEqual(bool, sections, true);
    for (rules, 0..) |given, i| {
        if (given.definition != .quantity) continue;
        const q = given.definition.quantity;
        const still = quantities.directed(q.quantity) and switch (given.scope) {
            .event => |event| (if (event.side == .in) in else out)[event.index],
            .section => |index| sections[index],
            .between => |ends| std.mem.allEqual(bool, sections[ends[0]..ends[1]], true),
            .all => whole,
            .time => |time| whole or restsBetween(rules, time, time),
            .time_range => |range| whole or restsBetween(rules, range[0], range[1]),
        };
        var asked = still and (q.comparison == .eq or (q.comparison != .range and !quantities.interval(given.scope)));
        const sides: [2]?model.Value = switch (q.comparison) {
            .eq, .target => |v| .{ v, null },
            .range => |range| .{ range.min, range.max },
            .objective => .{ null, null },
        };
        for (sides) |side| if (side) |v| {
            if (!still and v == .event and quantities.directed(v.event.quantity) and (if (v.event.side == .in) in else out)[v.event.event]) asked = true;
        };
        if (asked) return fail(ctx, .out_of_range, try node.element(ctx, "rules", i), "a direction of travel is asked where the plan holds the path at rest: a path at rest has none", .{});
    }
}

fn guess(c: Context, raw: ?read.RawGuess, altitude: model.Altitude, event_count: usize) Error!model.InitialGuess {
    const times = try c.ctx.arena.alloc(?f64, event_count);
    @memset(times, null);
    const given = raw orelse return .{ .event_times = times, .states = &.{} };
    if (given.event_times) |entries| for (entries.entries) |entry| {
        const path = try node.join(c.ctx, "initialGuess.eventTimes", entry.id);
        const index = try c.index(c.events, entry.id, path);
        if (index == 0 and entry.value != 0) return fail(c.ctx, .out_of_range, path, "the first event is fixed at zero seconds", .{});
        times[index] = entry.value;
    };
    var previous: f64 = 0;
    for (times[1..], 1..) |time, i| if (time) |t| {
        if (t <= previous) return fail(c.ctx, .out_of_range, "initialGuess.eventTimes", "given event times must increase; event {d} has time {d}", .{ i, t });
        previous = t;
    };
    const raw_states = given.states orelse &.{};
    const states = try c.ctx.arena.alloc(model.GuessState, raw_states.len);
    const seen = try c.ctx.arena.alloc(bool, event_count);
    @memset(seen, false);
    for (raw_states, states, 0..) |entry, *out, i| {
        const path = try node.element(c.ctx, "initialGuess.states", i);
        const event = try c.index(c.events, entry.event, try node.join(c.ctx, path, "event"));
        if (seen[event]) return fail(c.ctx, .duplicate, try node.join(c.ctx, path, "event"), "an initial state for this event is already given", .{});
        seen[event] = true;
        const ecef = if (entry.position) |v| geometry.toEcef(v.position(), altitude) else null;
        if (ecef) |v| if (!shared.trajectory.positionInRange(v)) return fail(c.ctx, .out_of_range, try node.join(c.ctx, path, "position"), "position lies outside the trajectory geocentre-radius domain", .{});
        out.* = .{ .event = event, .ecef = ecef, .velocity_ecef = if (entry.velocity_ecef) |v| v.value else null, .acceleration_ecef = if (entry.acceleration_ecef) |v| v.value else null };
    }
    return .{ .event_times = times, .states = states };
}
