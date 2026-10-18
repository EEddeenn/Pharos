//! The plan as read made whole: names to places, lengths to times, the events named; every fault of the plan's
//! text reported in one pass.
const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const node = shared.json.node;
const Number = node.Number;
const Escaped = core.diagnostics.Escaped;
const Range = shared.json.table.Range;
const model = @import("model.zig");
const geometry = @import("geometry.zig");
const read = @import("read.zig");

pub const Error = core.diagnostics.InputError;

pub const format_word = "pharos.trajectory-plan";

const Resolver = struct {
    ctx: *const node.Ctx,
    ok: bool = true,
    ids: std.StringHashMapUnmanaged(usize) = .empty,
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
};

pub fn resolve(ctx: *const node.Ctx, raw: read.Raw) Error!model.Plan {
    const arena = ctx.arena;
    var r: Resolver = .{ .ctx = ctx };
    if (!std.mem.eql(u8, raw.format, format_word)) try r.err(.invalid_format, "format", "must be \"" ++ format_word ++ "\", got \"{f}\"", .{Escaped{ .text = raw.format }});
    const altitude = raw.coordinates.altitude;
    const known = try places(ctx, altitude, raw.places, &r.ok);
    for (known, 0..) |p, i| try r.ids.put(arena, p.id, i);

    const start_place = try r.place("start.at", raw.start.at);
    const start: model.Start = blk: {
        const speed = raw.start.speed orelse {
            if (raw.start.course != null) try r.err(.out_of_range, "start.course", "a start with no speed takes no course", .{});
            break :blk .free;
        };
        if (speed == 0) {
            if (raw.start.course != null) try r.err(.out_of_range, "start.course", "a start at rest takes no course", .{});
            break :blk .rest;
        }
        const course = raw.start.course orelse {
            try r.err(.missing_field, "start.course", "required with a speed above 0", .{});
            break :blk .free;
        };
        const index = start_place orelse break :blk .free;
        const frame = core.coord.EnuFrame.at(core.coord.ecefToLla(known[index].ecef));
        const k = core.constants.deg2rad(course);
        const north = model.Vector.fromArray(frame.rows[1]);
        const east = model.Vector.fromArray(frame.rows[0]);
        break :blk .{ .moving = north.scale(@cos(k) * speed).add(east.scale(@sin(k) * speed)) };
    };

    var events: std.ArrayList(model.Event) = .empty;
    try events.append(arena, .{ .name = "start", .time = 0, .segment = null });
    try r.named.put(arena, "start", "the start");
    const segments = try arena.alloc(model.Segment, raw.segments.len);
    var now: f64 = 0;
    // Why the segment before ends moving, where it does: a stay must begin at rest, as the plan states it.
    var moving: ?[]const u8 = switch (start) {
        .rest => null,
        .free => "the start states no speed",
        .moving => "the start states a speed",
    };
    for (raw.segments, segments, 0..) |given, *out, i| {
        const path = try node.element(ctx, "segments", i);
        out.* = .{ .id = given.id, .end = now, .motion = .stay };
        const kinds = @as(u8, @intFromBool(given.stay != null)) + @intFromBool(given.through != null);
        if (kinds != 1) {
            try r.err(.out_of_range, path, "a segment takes one of stay, through; {d} given ({s})", .{ kinds, if (kinds == 0) "none" else "stay, through" });
        } else if (given.stay != null) {
            if (moving) |why| try r.err(.out_of_range, path, "a stay must begin at rest, and {s}", .{why});
            if (given.@"for" != null and given.time != null) {
                try r.err(.out_of_range, path, "a stay takes one of for, time; 2 given (for, time)", .{});
            } else if (given.@"for") |length| {
                out.end = now + length;
                if (!(out.end > now)) try r.err(.out_of_range, try node.join(ctx, path, "for"), "must end the stay after it begins at {d} s, got {f}", .{ now, Number{ .value = length } });
            } else if (given.time) |time| {
                try r.after(try node.join(ctx, path, "time"), time, now);
                out.end = @max(now, time);
            } else try r.err(.missing_field, path, "a stay takes one of for, time; 0 given (none)", .{});
            moving = null;
        } else {
            const through = given.through.?;
            inline for (.{ "for", "time" }) |key| {
                if (@field(given, key) != null) try r.err(.out_of_range, try node.join(ctx, path, key), "a through takes no " ++ key ++ ": the time of its last place ends it", .{});
            }
            const visits = try arena.alloc(model.Visit, through.places.len);
            const places_path = try node.join(ctx, path, "through.places");
            var last = now;
            for (through.places, visits, 0..) |visit, *v, j| {
                const visit_path = try node.element(ctx, places_path, j);
                try r.after(try node.join(ctx, visit_path, "time"), visit.time, last);
                last = @max(last, visit.time);
                v.* = .{ .place = try r.place(try node.join(ctx, visit_path, "at"), visit.at) orelse 0, .time = visit.time };
                const event = visit.event orelse visit.at;
                try r.name(try node.join(ctx, visit_path, if (visit.event != null) "event" else "at"), event);
                try events.append(arena, .{ .name = event, .time = visit.time, .segment = i, .visit = j });
            }
            out.* = .{ .id = given.id, .end = last, .motion = .{ .through = .{ .visits = visits, .end = through.end } } };
            moving = if (through.end == .rest) null else try arena.print("{s} ends free", .{path});
        }
        // Only the first segment to end too late is told: the ones after it end no earlier.
        if (out.end > shared.trajectory.max_duration_s and now <= shared.trajectory.max_duration_s) try r.err(.out_of_range, path, "ends {f} s from the start, and a trajectory lasts at most {d} s", .{ Number{ .value = out.end, .outside = .{ .max = shared.trajectory.max_duration_s } }, shared.trajectory.max_duration_s });
        now = out.end;
        if (given.id) |id| {
            try r.name(try node.join(ctx, path, "id"), id);
            try events.append(arena, .{ .name = id, .time = now, .segment = i });
        }
    }
    if (!r.ok) return error.InvalidInput;
    return .{
        .name = raw.name,
        .altitude = altitude,
        .places = known,
        .start_place = start_place.?,
        .start = start,
        .segments = segments,
        .events = events.items,
    };
}

/// The places in ECEF; a place whose id another took, or that lies outside the receiver's domain, is reported and
/// `ok` made false.
pub fn places(ctx: *const node.Ctx, altitude: model.Altitude, given: []const read.RawPlace, ok: *bool) Error![]const model.Place {
    const out = try ctx.arena.alloc(model.Place, given.len);
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    const domain: Range = .{ .min = shared.trajectory.min_radius_m, .max = shared.trajectory.max_radius_m };
    for (given, out, 0..) |p, *place, i| {
        const path = try node.element(ctx, "places", i);
        const lla = geometry.lla(p.latitude, p.longitude, p.altitude, altitude);
        place.* = .{ .id = p.id, .ecef = core.coord.llaToEcef(lla), .height = lla.height_m };
        const found = try seen.getOrPut(ctx.arena, p.id);
        if (found.found_existing) {
            try ctx.diags.err(.duplicate, try node.join(ctx, path, "id"), "the id \"{f}\" is given to places[{d}] too", .{ Escaped{ .text = p.id }, found.value_ptr.* });
            ok.* = false;
        } else found.value_ptr.* = i;
        const radius = place.ecef.norm();
        if (!domain.holds(radius)) {
            try ctx.diags.err(.out_of_range, try node.join(ctx, path, "altitude"), "the place's distance from the geocentre must be {f} m, got {f}", .{ domain, Number{ .value = radius, .outside = domain } });
            ok.* = false;
        }
    }
    return out;
}
