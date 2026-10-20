//! The plan as read made whole: names to places and guides, angles to radians, the events named; every fault of the
//! plan's text reported in one pass. What only numbers decide (a length, a time that follows from one) is the
//! build's to check.
const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const node = shared.json.node;
const Number = node.Number;
const Escaped = core.diagnostics.Escaped;
const Range = shared.json.table.Range;
const deg2rad = core.constants.deg2rad;
const model = @import("model.zig");
const geometry = @import("geometry.zig");
const read = @import("read.zig");

pub const Error = core.diagnostics.InputError;

pub const format_word = "pharos.trajectory-plan";

/// How the segment before leaves the path, as the plan's text says.
const Before = struct {
    motion: enum { rest, free, moving },
    /// Whether a direction of travel is known: moving, and not after a through.
    direction: bool,
    /// The place the segment begins at, by identity.
    at: ?usize,
    /// The guide an along before ended on, and where on it.
    guide: ?OnGuide = null,
    /// Why it ends moving, for a stay that follows.
    why: []const u8 = "",
};

/// A guide by its index, and a place of it by the place's index in the guide.
const OnGuide = struct { index: usize, place: usize };

const Resolver = struct {
    ctx: *const node.Ctx,
    ok: bool = true,
    ids: std.StringHashMapUnmanaged(usize) = .empty,
    guide_ids: std.StringHashMapUnmanaged(usize) = .empty,
    /// Where each event's name is given, by name.
    named: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn err(self: *Resolver, code: core.diagnostics.Code, path: []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try self.ctx.diags.err(code, path, fmt, args);
        self.ok = false;
    }

    fn place(self: *Resolver, path: []const u8, id: []const u8) Error!?usize {
        if (self.ids.get(id)) |index| return index;
        try self.err(.unknown_name, path, "no place has the id \"{f}\"", .{Escaped{ .text = id }});
        return null;
    }

    fn name(self: *Resolver, path: []const u8, event: []const u8) Error!void {
        const found = try self.named.getOrPut(self.ctx.arena, event);
        if (found.found_existing) return self.err(.duplicate, path, "the event \"{f}\" is named twice: {s} names it too", .{ Escaped{ .text = event }, found.value_ptr.* });
        found.value_ptr.* = path;
    }

    /// A time that must come after the one before it.
    fn after(self: *Resolver, path: []const u8, time: f64, before: f64) Error!void {
        const range: Range = .{ .min = before, .open_min = true };
        if (!range.holds(time)) try self.err(.out_of_range, path, "must be {f}, got {f}", .{ range, Number{ .value = time, .outside = range } });
    }

    fn join(self: *Resolver, path: []const u8, key: []const u8) Error![]const u8 {
        return node.join(self.ctx, path, key);
    }
};

pub fn resolve(ctx: *const node.Ctx, raw: read.Raw) Error!model.Plan {
    const arena = ctx.arena;
    var r: Resolver = .{ .ctx = ctx };
    if (!std.mem.eql(u8, raw.format, format_word)) try r.err(.invalid_format, "format", "must be \"" ++ format_word ++ "\", got \"{f}\"", .{Escaped{ .text = raw.format }});
    const altitude = raw.coordinates.altitude;
    const known = try places(ctx, altitude, raw.places, &r.ok);
    for (known, 0..) |p, i| try r.ids.put(arena, p.id, i);
    const guides = try arena.alloc(model.Guide, if (raw.guides) |g| g.len else 0);
    for (raw.guides orelse &.{}, guides, 0..) |given, *out, i| out.* = try guide(&r, i, given);

    const start_place = try r.place("start.at", raw.start.at);
    const start: model.Start = .{ .speed = raw.start.speed, .course = if (raw.start.course) |c| deg2rad(c) else null };
    try startCourse(&r, raw);

    var events: std.ArrayList(model.Event) = .empty;
    try events.append(arena, .{ .name = "start", .segment = null });
    try r.named.put(arena, "start", "the start");
    const segments = try arena.alloc(model.Segment, raw.segments.len);
    // The time the segment before ends, where the plan's text gives it; null after a segment whose time follows
    // from its length and speed (the build checks the times after it).
    var now: ?f64 = 0;
    var before: Before = .{
        .motion = if (start.speed) |s| if (s == 0) .rest else .moving else .free,
        .direction = start.course != null,
        .at = start_place,
        .why = if (start.speed == null) "the start states no speed" else "the start states a speed",
    };
    for (raw.segments, segments, 0..) |given, *out, i| {
        const path = try node.element(ctx, "segments", i);
        out.* = (try segment(&r, path, given, before, now, guides, &events, i)) orelse .{ .id = given.id, .span = null, .speed = null, .climb = null, .altitude = null, .motion = .stay };
        const end: ?f64 = switch (out.motion) {
            .through => |t| if (t.visits.len > 0) t.visits[t.visits.len - 1].time else now,
            else => if (out.span) |span| switch (span) {
                .duration => |d| if (now) |n| n + d else null,
                .until => |t| t,
            } else null,
        };
        if (now) |n| if (out.span) |span| switch (span) {
            .duration => |d| if (!(n + d > n)) try r.err(.out_of_range, try r.join(path, "for"), "must end the {s} after it begins at {f} s, got an end at {f} s", .{ model.Kind.words.get(out.motion), Number{ .value = n }, Number{ .value = n + d } }),
            .until => |t| try r.after(try r.join(path, "time"), t, n),
        };
        // Only the first segment to end too late is told: the ones after it end no earlier.
        if (end) |e| if (e > shared.trajectory.max_duration_s and (now orelse 0) <= shared.trajectory.max_duration_s) {
            try r.err(.out_of_range, path, "ends {f} s from the start, and a trajectory lasts at most {d} s", .{ Number{ .value = e, .outside = .{ .max = shared.trajectory.max_duration_s } }, shared.trajectory.max_duration_s });
        };
        now = if (end) |e| if (now) |n| @max(n, e) else e else null;
        before = try leaves(&r, path, out.*, before, guides);
        if (given.id) |id| {
            try r.name(try r.join(path, "id"), id);
            try events.append(arena, .{ .name = id, .segment = i });
        }
    }
    const checks = try limits(&r, raw);
    if (!r.ok) return error.InvalidInput;
    return .{
        .name = raw.name,
        .altitude = altitude,
        .places = known,
        .guides = guides,
        .start_place = start_place.?,
        .start = start,
        .segments = segments,
        .events = events.items,
        .limits = checks,
    };
}

/// The limits, their segments by index: a max or a min or both; a min of a speed or the altitude only, not above
/// the max; neither below 0 but the altitude's.
fn limits(r: *Resolver, raw: read.Raw) Error![]const model.Limit {
    const arena = r.ctx.arena;
    const given = raw.limits orelse &.{};
    var segment_ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (raw.segments, 0..) |s, i| if (s.id) |id| {
        const found = try segment_ids.getOrPut(arena, id);
        if (!found.found_existing) found.value_ptr.* = i;
    };
    var limit_ids: std.StringHashMapUnmanaged(usize) = .empty;
    const out = try arena.alloc(model.Limit, given.len);
    for (given, out, 0..) |limit, *resolved, i| {
        const path = try node.element(r.ctx, "limits", i);
        const quantity = limit.quantity;
        if (limit.id) |id| {
            const found = try limit_ids.getOrPut(arena, id);
            if (found.found_existing) {
                try r.err(.duplicate, try r.join(path, "id"), "the id \"{f}\" is given to limits[{d}] too", .{ Escaped{ .text = id }, found.value_ptr.* });
            } else found.value_ptr.* = i;
        }
        if (limit.max == null and limit.min == null) try r.err(.missing_field, path, "a limit takes a max or a min, or both; 0 given (none)", .{});
        if (quantity != .altitude) for ([_]?f64{ limit.max, limit.min }, [_][]const u8{ "max", "min" }) |bound, key| if (bound) |value| {
            const range: Range = .{ .min = 0 };
            if (!range.holds(value)) try r.err(.out_of_range, try r.join(path, key), "must be {f}, got {f}", .{ range, Number{ .value = value, .outside = range } });
        };
        if (limit.min) |min| {
            if (quantity != .speed3d and quantity != .horizontal_speed and quantity != .altitude) {
                try r.err(.out_of_range, try r.join(path, "min"), "a limit of {s} takes no min: only a speed or the altitude does", .{model.Quantity.names.get(quantity)});
            } else if (limit.max) |max| if (min > max) {
                try r.err(.out_of_range, try r.join(path, "min"), "must be at most {f}, the max, got {f}", .{ Number{ .value = max }, Number{ .value = min, .apart = max } });
            };
        }
        var over: ?[]usize = null;
        if (limit.over) |ids| {
            const segments = try arena.alloc(usize, ids.len);
            var named_ids: std.StringHashMapUnmanaged(usize) = .empty;
            for (ids, segments, 0..) |id, *named, j| {
                const where = try node.element(r.ctx, try r.join(path, "over"), j);
                named.* = segment_ids.get(id) orelse blk: {
                    try r.err(.unknown_name, where, "no segment has the id \"{f}\"", .{Escaped{ .text = id }});
                    break :blk 0;
                };
                const found = try named_ids.getOrPut(arena, id);
                if (found.found_existing) {
                    try r.err(.duplicate, where, "the id \"{f}\" is given to over[{d}] too", .{ Escaped{ .text = id }, found.value_ptr.* });
                } else found.value_ptr.* = j;
            }
            over = segments;
        }
        resolved.* = .{ .id = limit.id, .quantity = quantity, .max = limit.max, .min = limit.min, .over = over };
    }
    return out;
}

/// The start's course: at rest none; where the first segment gives its own direction none; where it takes its
/// direction from the start, required.
fn startCourse(r: *Resolver, raw: read.Raw) Error!void {
    const first = raw.segments[0];
    const speed = raw.start.speed;
    const given = raw.start.course != null;
    if (speed != null and speed.? == 0) {
        if (given) try r.err(.out_of_range, "start.course", "a start at rest takes no course", .{});
    } else if (first.through != null) {
        if (speed == null and given) try r.err(.out_of_range, "start.course", "a start with no speed takes no course", .{});
        if (speed != null and !given) try r.err(.missing_field, "start.course", "required with a speed above 0", .{});
    } else if (first.along != null or (first.straight != null and (first.straight.?.course != null or first.straight.?.to != null))) {
        if (given) try r.err(.out_of_range, "start.course", "the first segment gives its own direction, so the start takes no course", .{});
    } else if (first.turn != null or first.straight != null) {
        if (!given) try r.err(.missing_field, "start.course", "required: the first segment takes its direction from the start", .{});
    }
}

fn guide(r: *Resolver, index: usize, given: read.RawGuide) Error!model.Guide {
    const path = try node.element(r.ctx, "guides", index);
    const found = try r.guide_ids.getOrPut(r.ctx.arena, given.id);
    if (found.found_existing) {
        try r.err(.duplicate, try r.join(path, "id"), "the id \"{f}\" is given to guides[{d}] too", .{ Escaped{ .text = given.id }, found.value_ptr.* });
    } else found.value_ptr.* = index;
    var out: model.Guide = .{ .id = given.id, .places = &.{}, .shape = .bezier };
    const kinds = @as(u8, @intFromBool(given.polyline != null)) + @intFromBool(given.bezier != null);
    if (kinds != 1) {
        try r.err(.out_of_range, path, "a guide takes one of polyline, bezier; {d} given ({s})", .{ kinds, if (kinds == 0) "none" else "polyline, bezier" });
        return out;
    }
    const names = if (given.polyline) |p| p.places else given.bezier.?.places;
    const places_path = try r.join(path, if (given.polyline != null) "polyline.places" else "bezier.places");
    if (given.polyline) |p| out.shape = .{ .polyline = p.radius };
    if (given.bezier != null and names.len % 3 != 1) try r.err(.out_of_range, places_path, "a Bezier takes four places, and three more for each piece after the first; got {d}", .{names.len});
    const indices = try r.ctx.arena.alloc(usize, names.len);
    for (names, indices, 0..) |id, *place, j| place.* = try r.place(try node.element(r.ctx, places_path, j), id) orelse 0;
    out.places = indices;
    return out;
}

/// The places of a guide that its path reaches: a Bezier's first and the last of each piece; a polyline's every
/// place, a corner at its arc's middle.
fn reaches(g: model.Guide, index: usize) bool {
    return switch (g.shape) {
        .polyline => true,
        .bezier => index % 3 == 0,
    };
}

/// The places its path passes exactly, where an along can begin: a polyline's corner is rounded off.
fn passes(g: model.Guide, index: usize) bool {
    return switch (g.shape) {
        .polyline => index == 0 or index == g.places.len - 1,
        .bezier => index % 3 == 0,
    };
}

/// The index in `g` of the first place, from `from` on, that is `place` and that `on` holds of its index.
fn indexOf(g: model.Guide, place: usize, from: usize, comptime on: fn (model.Guide, usize) bool) ?usize {
    for (g.places[from..], from..) |p, i| if (p == place and on(g, i)) return i;
    return null;
}

fn kindName(given: read.RawSegment) ?model.Kind {
    var found: ?model.Kind = null;
    inline for (comptime std.enums.values(model.Kind)) |kind| {
        if (@field(given, @tagName(kind)) != null) {
            if (found != null) return null;
            found = kind;
        }
    }
    return found;
}

fn segment(r: *Resolver, path: []const u8, given: read.RawSegment, before: Before, now: ?f64, guides: []const model.Guide, events: *std.ArrayList(model.Event), index: usize) Error!?model.Segment {
    const kind = kindName(given) orelse {
        var count: u8 = 0;
        var list: std.ArrayList(u8) = .empty;
        inline for (comptime std.enums.values(model.Kind)) |k| if (@field(given, @tagName(k)) != null) {
            count += 1;
            try list.appendSlice(r.ctx.arena, if (list.items.len == 0) @tagName(k) else ", " ++ @tagName(k));
        };
        try r.err(.out_of_range, path, "a segment takes one of stay, straight, turn, along, through; {d} given ({s})", .{ count, if (count == 0) "none" else list.items });
        return null;
    };
    const word = model.Kind.words.get(kind);
    var out: model.Segment = .{ .id = given.id, .span = null, .speed = given.speed, .climb = given.climb, .altitude = given.altitude, .motion = .stay };
    if (given.@"for" != null and given.time != null) {
        try r.err(.out_of_range, path, "a {s} takes one of for, time; 2 given (for, time)", .{word});
    } else if (given.@"for") |d| {
        out.span = .{ .duration = d };
    } else if (given.time) |t| out.span = .{ .until = t };
    switch (kind) {
        .stay => {
            if (before.motion != .rest) try r.err(.out_of_range, path, "a stay must begin at rest, and {s}", .{before.why});
            if (given.@"for" == null and given.time == null) try r.err(.missing_field, path, "a stay takes one of for, time; 0 given (none)", .{});
            try none(r, path, given, "a stay", "it is at rest", &.{ "speed", "climb", "altitude" });
        },
        .through => {
            inline for (.{ "for", "time" }) |key| {
                if (@field(given, key) != null) try r.err(.out_of_range, try r.join(path, key), "a through takes no " ++ key ++ ": the time of its last place ends it", .{});
            }
            try none(r, path, given, "a through", "its places at their times make its motion", &.{ "speed", "climb", "altitude" });
            out.span = null;
            out.motion = .{ .through = try through(r, path, given.through.?, now, events, index) };
        },
        .straight => {
            const s = given.straight.?;
            const to = if (s.to) |id| try r.place(try r.join(path, "straight.to"), id) else null;
            if (s.to != null and s.course != null) try r.err(.out_of_range, try r.join(path, "straight.course"), "a straight to a place takes no course: the place gives it", .{});
            if (s.to != null and s.distance != null) try r.err(.out_of_range, try r.join(path, "straight.distance"), "a straight to a place takes no distance: the place gives it", .{});
            if (s.to != null and given.altitude != null) try r.err(.out_of_range, try r.join(path, "altitude"), "a straight to a place takes no altitude: the place gives it", .{});
            const own = s.course != null or s.to != null;
            if (own and before.motion == .moving and index > 0) {
                try r.err(.out_of_range, try r.join(path, if (s.to != null) "straight.to" else "straight.course"), "a straight that begins moving keeps the direction it begins in: a course or a to only at rest, at the start or after a through", .{});
            } else if (!own and !before.direction and (index > 0 or before.motion == .rest)) {
                // At the start, moving or free, the start's course is what is missing (startCourse).
                try r.err(.missing_field, try r.join(path, "straight"), "a straight that begins {s} takes a course or a to", .{if (before.motion == .rest) "at rest" else "after a through"});
            }
            out.motion = .{ .straight = .{ .course = if (s.course) |c| deg2rad(c) else null, .to = to, .distance = s.distance } };
            try speeds(r, path, given, before, s.to != null or s.distance != null, false);
        },
        .turn => {
            const t = given.turn.?;
            const bends = @as(u8, @intFromBool(t.radius != null)) + @intFromBool(t.rate != null) + @intFromBool(t.lateral != null);
            if (bends != 1) try r.err(.out_of_range, try r.join(path, "turn"), "a turn takes one of radius, rate, lateral; {d} given ({s})", .{ bends, if (bends == 0) "none" else try givenList(r, t) });
            if (t.onto != null and t.by != null) try r.err(.out_of_range, try r.join(path, "turn"), "a turn takes at most one of onto, by; 2 given (onto, by)", .{});
            const bend: model.Bend = if (t.radius) |v| .{ .radius = v } else if (t.rate) |v| .{ .rate = deg2rad(v) } else .{ .lateral = t.lateral orelse 1 };
            inline for (.{ "radius", "rate", "lateral", "by" }) |key| if (@field(t, key)) |v| if (v == 0) {
                try r.err(.out_of_range, try r.join(path, "turn." ++ key), "must not be 0", .{});
            };
            // By the value given: a rate in degrees can be too small to be one in radians.
            const sign = t.radius orelse t.rate orelse t.lateral orelse 1;
            if (t.by) |by| if (by != 0 and sign != 0 and (by > 0) != (sign > 0)) {
                try r.err(.out_of_range, try r.join(path, "turn.by"), "a turn to the {s} turns by an angle {s} 0, got {f}", .{ if (sign > 0) "right" else "left", if (sign > 0) "above" else "below", Number{ .value = by } });
            };
            if (before.motion == .rest) {
                try r.err(.out_of_range, path, "a turn must begin moving: it begins at rest", .{});
            } else if (!before.direction and index > 0) {
                try r.err(.out_of_range, path, "a turn cannot follow a through: it has no course to begin from", .{});
            }
            const keeps = bend != .radius;
            const fixed = t.onto != null or t.by != null;
            if (keeps and before.motion != .free and given.speed != null) try r.err(.out_of_range, try r.join(path, "speed"), "a turn by {s} keeps its speed: it takes no speed", .{@tagName(bend)});
            if (keeps and fixed and out.span != null) try r.err(.out_of_range, try r.join(path, if (given.@"for" != null) "for" else "time"), "a turn by {s} keeps its speed, so its {s} fixes its time: it takes no {s}", .{ @tagName(bend), if (t.onto != null) "onto" else "by", if (given.@"for" != null) "for" else "time" });
            out.motion = .{ .turn = .{ .bend = bend, .end = if (t.onto) |c| .{ .onto = deg2rad(c) } else if (t.by) |b| .{ .by = deg2rad(b) } else .open } };
            if (!(keeps and before.motion != .free)) try speeds(r, path, given, before, fixed, keeps);
            if (keeps and !fixed and out.span == null) try r.err(.missing_field, path, "a turn with neither an onto nor a by takes one of for, time; 0 given (none)", .{});
        },
        .along => {
            const a = given.along.?;
            try none(r, path, given, "an along", "its guide's places give its heights", &.{ "climb", "altitude" });
            const found = for (guides, 0..) |g, k| {
                if (std.mem.eql(u8, g.id, a.guide)) break k;
            } else null;
            const g_index = found orelse {
                try r.err(.unknown_name, try r.join(path, "along.guide"), "no guide has the id \"{f}\"", .{Escaped{ .text = a.guide }});
                return null;
            };
            const g = guides[g_index];
            if (g.places.len == 0) return null;
            // Where on the guide it begins: where an along before left it, or the first place there the guide
            // passes.
            const continues = if (before.guide) |on| on.index == g_index else false;
            const from = if (continues) before.guide.?.place else if (before.at) |p| indexOf(g, p, 0, passes) else null;
            const guide_path = try r.join(path, "along.guide");
            if (from == null) {
                try r.err(.out_of_range, guide_path, "the guide \"{f}\" does not pass the place where the along begins", .{Escaped{ .text = g.id }});
            } else if (!continues and before.motion == .moving and index > 0) {
                try r.err(.out_of_range, guide_path, "an along that begins moving goes on along the guide the segment before follows: another guide, or another place of it, only at rest, at the start or after a through", .{});
            }
            const start = from orelse 0;
            var to = g.places.len - 1;
            if (a.to) |id| if (try r.place(try r.join(path, "along.to"), id)) |p| {
                to = indexOf(g, p, start + 1, reaches) orelse blk: {
                    try r.err(.out_of_range, try r.join(path, "along.to"), "the guide \"{f}\" passes no \"{f}\" after the place where the along begins", .{ Escaped{ .text = g.id }, Escaped{ .text = id } });
                    break :blk to;
                };
            };
            if (from != null and !(to > start)) try r.err(.out_of_range, guide_path, "the along begins at the end of its guide", .{});
            out.motion = .{ .along = .{ .guide = g_index, .from = start, .to = to } };
            try speeds(r, path, given, before, true, false);
        },
    }
    return out;
}

/// The keys a segment of this kind takes none of.
fn none(r: *Resolver, path: []const u8, given: read.RawSegment, comptime what: []const u8, comptime why: []const u8, comptime keys: []const []const u8) Error!void {
    inline for (keys) |key| {
        if (@field(given, key) != null) try r.err(.out_of_range, try r.join(path, key), what ++ " takes no " ++ key ++ ": " ++ why, .{});
    }
}

fn givenList(r: *Resolver, t: read.RawTurn) Error![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    inline for (.{ "radius", "rate", "lateral" }) |key| if (@field(t, key) != null) {
        try list.appendSlice(r.ctx.arena, if (list.items.len == 0) key else ", " ++ key);
    };
    return list.items;
}

/// The speed, length and time of a built segment: where its shape fixes its length (`fixed`), a speed or a for or a
/// time, not both, and neither keeps the speed; where it does not, a for or a time, and a speed where it begins at
/// rest or free. `keeps`: a turn by rate or lateral after a free start, whose speed sets its curvature.
fn speeds(r: *Resolver, path: []const u8, given: read.RawSegment, before: Before, fixed: bool, keeps: bool) Error!void {
    const span = given.@"for" != null or given.time != null;
    if (fixed and !keeps) {
        if (span and given.speed != null) {
            try r.err(.out_of_range, try r.join(path, "speed"), "the segment's shape fixes its length, so it takes a speed or one of for, time, not both", .{});
        } else if (!span and given.speed == null and before.motion != .moving) {
            try r.err(.missing_field, path, "a segment that begins {s} takes a speed or one of for, time; 0 given (none)", .{if (before.motion == .rest) "at rest" else "at no speed of its own"});
        } else if (given.speed) |v| if (v == 0 and before.motion == .rest) {
            try r.err(.out_of_range, try r.join(path, "speed"), "a segment that begins at rest and ends at rest does not move: must be above 0, got 0", .{});
        };
    } else {
        if (!span and !keeps) try r.err(.missing_field, path, "a segment whose shape does not fix its length takes one of for, time; 0 given (none)", .{});
        if (given.speed == null and before.motion != .moving) {
            try r.err(.missing_field, try r.join(path, "speed"), "required: the segment begins {s}", .{if (before.motion == .rest) "at rest" else "at no speed of its own"});
        } else if (given.speed) |v| if (v == 0 and before.motion == .rest) {
            try r.err(.out_of_range, try r.join(path, "speed"), "a segment that begins at rest and ends at rest does not move: must be above 0, got 0", .{});
        };
    }
    if (given.speed) |v| if (v == 0) if (given.climb) |c| if (c != 0) {
        try r.err(.out_of_range, try r.join(path, "climb"), "a segment that ends at rest ends with no climb: must be 0, got {f}", .{Number{ .value = c }});
    };
}

/// A through's places, each after the one before it and the first after the segment's start, where the plan's
/// text gives that (`now`).
fn through(r: *Resolver, path: []const u8, given: read.RawThrough, now: ?f64, events: *std.ArrayList(model.Event), index: usize) Error!model.Through {
    const visits = try r.ctx.arena.alloc(model.Visit, given.places.len);
    const places_path = try r.join(path, "through.places");
    var last = now;
    for (given.places, visits, 0..) |visit, *v, j| {
        const visit_path = try node.element(r.ctx, places_path, j);
        if (last) |l| try r.after(try r.join(visit_path, "time"), visit.time, l);
        last = if (last) |l| @max(l, visit.time) else visit.time;
        v.* = .{ .place = try r.place(try r.join(visit_path, "at"), visit.at) orelse 0, .time = last.? };
        const event = visit.event orelse visit.at;
        try r.name(try r.join(visit_path, if (visit.event != null) "event" else "at"), event);
        try events.append(r.ctx.arena, .{ .name = event, .segment = index, .visit = j });
    }
    return .{ .visits = visits, .end = given.end };
}

/// How a segment leaves the path for the one after it.
fn leaves(r: *Resolver, path: []const u8, segment_: model.Segment, before: Before, guides: []const model.Guide) Error!Before {
    return switch (segment_.motion) {
        .stay => .{ .motion = .rest, .direction = false, .at = before.at, .guide = before.guide },
        .through => |t| .{
            .motion = if (t.end == .rest) .rest else .free,
            .direction = false,
            .at = if (t.visits.len > 0) t.visits[t.visits.len - 1].place else before.at,
            .why = try r.ctx.arena.print("{s} ends free", .{path}),
        },
        .straight => |s| built(r, path, segment_, s.to, null),
        .turn => built(r, path, segment_, null, null),
        .along => |a| blk: {
            const g = guides[a.guide];
            // A polyline's corner is passed at its arc's middle, not at its place.
            const exact = g.shape == .bezier or a.to == g.places.len - 1;
            break :blk built(r, path, segment_, if (exact) g.places[a.to] else null, .{ .index = a.guide, .place = a.to });
        },
    };
}

fn built(r: *Resolver, path: []const u8, segment_: model.Segment, place: ?usize, on: ?OnGuide) Error!Before {
    const rest = if (segment_.speed) |v| v == 0 else false;
    return .{
        .motion = if (rest) .rest else .moving,
        .direction = !rest,
        .at = place,
        .guide = on,
        .why = try r.ctx.arena.print("{s} ends moving", .{path}),
    };
}

/// The places in ECEF; a place whose id another took, or that lies outside the receiver's domain, is reported and
/// `ok` made false.
fn places(ctx: *const node.Ctx, altitude: model.Altitude, given: []const read.RawPlace, ok: *bool) Error![]const model.Place {
    const out = try ctx.arena.alloc(model.Place, given.len);
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    for (given, out, 0..) |p, *place, i| {
        const path = try node.element(ctx, "places", i);
        place.* = at(p.id, p.latitude, p.longitude, p.altitude, altitude);
        const found = try seen.getOrPut(ctx.arena, p.id);
        if (found.found_existing) {
            try ctx.diags.err(.duplicate, try node.join(ctx, path, "id"), "the id \"{f}\" is given to places[{d}] too", .{ Escaped{ .text = p.id }, found.value_ptr.* });
            ok.* = false;
        } else found.value_ptr.* = i;
        if (!try inDomain(ctx, path, place.*)) ok.* = false;
    }
    return out;
}

const domain: Range = .{ .min = shared.trajectory.min_radius_m, .max = shared.trajectory.max_radius_m };

fn at(id: []const u8, latitude: f64, longitude: f64, altitude_m: f64, altitude: model.Altitude) model.Place {
    const lla = geometry.lla(latitude, longitude, altitude_m, altitude);
    return .{ .id = id, .ecef = core.coord.llaToEcef(lla), .height = lla.height_m, .altitude = altitude_m };
}

fn inDomain(ctx: *const node.Ctx, path: []const u8, place: model.Place) Error!bool {
    const radius = place.ecef.norm();
    if (domain.holds(radius)) return true;
    try ctx.diags.err(.out_of_range, try node.join(ctx, path, "altitude"), "the place's distance from the geocentre must be {f} m, got {f}", .{ domain, Number{ .value = radius, .outside = domain } });
    return false;
}

/// A guide of a plan being written: whole where its kind, its places and their coordinates are all given.
pub const Drawn = struct {
    id: ?[]const u8,
    guide: ?model.Guide,
};

/// The guides of a plan being written, each whole or not; their places in `places`.
pub const Sketch = struct {
    places: []const model.Place,
    guides: []const Drawn,
};

/// A plan's guides as far as they are whole: a place or a guide with a fault, which `diags` is told, is not whole,
/// and the others are read all the same.
pub fn drawn(ctx: *const node.Ctx, raw: read.Partial) Error!Sketch {
    const arena = ctx.arena;
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    var known: std.ArrayList(model.Place) = .empty;
    const altitude = if (raw.coordinates) |n| if (try element(read.PartialCoordinates, n)) |c| c.altitude else null else null;
    for (raw.places orelse &.{}, 0..) |n, i| {
        const p = try element(read.PartialPlace, n) orelse continue;
        const id = p.id orelse continue;
        const path = try node.element(ctx, "places", i);
        const found = try ids.getOrPut(arena, id);
        if (found.found_existing) {
            try ctx.diags.err(.duplicate, try node.join(ctx, path, "id"), "the id \"{f}\" is given to places[{d}] too", .{ Escaped{ .text = id }, found.value_ptr.* });
            continue;
        }
        found.value_ptr.* = i;
        const reference = altitude orelse continue;
        const place = at(id, p.latitude orelse continue, p.longitude orelse continue, p.altitude orelse continue, reference);
        if (!try inDomain(ctx, path, place)) continue;
        try known.append(arena, place);
    }
    // The whole places by name, at their index in `known`: a place given but not whole names none.
    var whole: std.StringHashMapUnmanaged(usize) = .empty;
    for (known.items, 0..) |p, i| try whole.put(arena, p.id, i);
    const out = try arena.alloc(Drawn, if (raw.guides) |g| g.len else 0);
    var guide_ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (raw.guides orelse &.{}, out, 0..) |n, *d, i| {
        // A guide with a fault is named as it is given.
        d.* = .{ .id = givenId(n), .guide = null };
        const given = try element(read.PartialGuide, n) orelse continue;
        if (given.id) |id| {
            const found = try guide_ids.getOrPut(arena, id);
            if (found.found_existing) {
                try ctx.diags.err(.duplicate, try node.join(ctx, try node.element(ctx, "guides", i), "id"), "the id \"{f}\" is given to guides[{d}] too", .{ Escaped{ .text = id }, found.value_ptr.* });
                continue;
            }
            found.value_ptr.* = i;
        }
        if (given.polyline != null and given.bezier != null) {
            try ctx.diags.err(.out_of_range, try node.element(ctx, "guides", i), "a guide takes one of polyline, bezier; 2 given (polyline, bezier)", .{});
            continue;
        }
        const names = (if (given.polyline) |p| p.places else if (given.bezier) |b| b.places else null) orelse continue;
        if (given.polyline != null and (names.len < 2 or given.polyline.?.radius == null)) continue;
        if (given.bezier != null and (names.len < 4 or names.len % 3 != 1)) continue;
        const indices = try arena.alloc(usize, names.len);
        for (names, indices) |name, *index| index.* = whole.get(name) orelse break else {
            d.guide = .{ .id = given.id orelse "", .places = indices, .shape = if (given.polyline) |p| .{ .polyline = p.radius.? } else .bezier };
        }
    }
    return .{ .places = known.items, .guides = out };
}

/// An object of a plan being written, read on its own: null where it has a fault.
fn element(comptime T: type, n: node.Node) Error!?T {
    return shared.json.table.read(T, try n.object() orelse return null);
}

/// The id an object gives as text, whatever else it holds.
fn givenId(n: node.Node) ?[]const u8 {
    const map = switch (n.value) {
        .object => |m| m,
        else => return null,
    };
    return switch (map.get("id") orelse return null) {
        .string => |s| s,
        else => null,
    };
}
