const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const types = core.types;
const GpsTime = core.time.GpsTime;
const civil = core.civil;
const glonass = gnss.glonass.records;
const records = gnss.records;
const NavSet = bundle.navigation.NavSet;
const Ref = bundle.plan.Ref;
const Interval = bundle.plan.Interval;
const resolve = @import("resolve.zig");
const air = @import("air.zig").air;

const kepler_window_s: f64 = gnss.kepler.window_s;
const flight_after_tb_ms: u32 = 1_800_000;

fn healthy(e: *const records.KeplerEphemeris) bool {
    return e.extra.healthy();
}

pub fn recordBefore(a: *const records.KeplerEphemeris, b: *const records.KeplerEphemeris) bool {
    if (a.source() != b.source()) return @backingInt(a.source()) < @backingInt(b.source());
    if (!a.toe.eql(b.toe)) return b.toe.lessThan(a.toe);
    if (!a.toc.eql(b.toc)) return b.toc.lessThan(a.toc);
    if (a.iode != b.iode) return a.iode < b.iode;
    if (a.iodc != b.iodc) return a.iodc < b.iodc;
    inline for (@typeInfo(records.KeplerEphemeris).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "group_delay")) {
            for (std.enums.values(records.GroupDelayTerm)) |term| {
                const order = valueOrder(a.group_delay.get(term), b.group_delay.get(term));
                if (order != .eq) return order == .lt;
            }
        } else {
            const order = valueOrder(@field(a, name), @field(b, name));
            if (order != .eq) return order == .lt;
        }
    }
    return false;
}

fn valueOrder(a: anytype, b: @TypeOf(a)) std.math.Order {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .bool => return std.math.order(@intFromBool(a), @intFromBool(b)),
        .int => return std.math.order(a, b),
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            const left: Bits = @bitCast(a);
            const right: Bits = @bitCast(b);
            return std.math.order(left, right);
        },
        .@"enum" => return std.math.order(@backingInt(a), @backingInt(b)),
        .optional => {
            const left = a orelse return if (b == null) .eq else .lt;
            return valueOrder(left, b orelse return .gt);
        },
        .@"struct" => |s| inline for (s.field_names) |name| {
            const order = valueOrder(@field(a, name), @field(b, name));
            if (order != .eq) return order;
        },
        .@"union" => |u| {
            const tag = std.meta.activeTag(a);
            const other = std.meta.activeTag(b);
            if (tag != other) return valueOrder(tag, other);
            inline for (u.field_names) |name| {
                if (@field(std.meta.Tag(T), name) == tag) return valueOrder(@field(a, name), @field(b, name));
            }
            unreachable;
        },
        else => @compileError("unsupported record field " ++ @typeName(T)),
    }
    return .eq;
}

pub fn reference(set: *const NavSet, sat: types.SatId, t: GpsTime, signals: std.EnumSet(types.Signal), leap: civil.Leap) ?Ref {
    if (sat.system == .glo) return .{ .glonass = glonassFlight(set, sat, t, leap) orelse return null };
    const candidates = sourcesAt(set, sat, t, leap);
    for ([_]bool{ true, false }) |enabled| {
        for (std.enums.values(records.NavSource)) |source| {
            if (carries(signals, source.family()) != enabled) continue;
            const index = candidates.get(source).record(set) orelse continue;
            if (signals.count() != 0) {
                const candidate = resolve.binding(set, .{ .kepler = index }, t, leap);
                var it = signals.iterator();
                const alive = while (it.next()) |signal| {
                    if (air(set, &candidate, signals, signal).status == .on_air) break true;
                } else false;
                if (!alive) continue;
            }
            return .{ .kepler = index };
        }
    }
    return null;
}

fn carries(signals: std.EnumSet(types.Signal), family: types.NavFamily) bool {
    var it = signals.iterator();
    while (it.next()) |signal| if (gnss.spec.get(signal).family == family) return true;
    return false;
}

fn glonassFlight(set: *const NavSet, sat: types.SatId, t: GpsTime, leap: civil.Leap) ?u32 {
    var latest: ?GpsTime = null;
    for (set.glonass) |*g| {
        if (g.sat != sat or t.lessThan(glonass.adoption(g, leap))) continue;
        if (latest == null or latest.?.lessThan(g.tb)) latest = g.tb;
    }
    const tb = latest orelse return null;
    for (set.glonass, 0..) |*g, i| {
        if (g.sat == sat and g.tb.eql(tb) and t.lessThan(until(g, leap))) return @intCast(i);
    }
    return null;
}

pub fn reaches(arena: std.mem.Allocator, set: *const NavSet, system: types.System, leap: civil.Leap) std.mem.Allocator.Error![]const Interval {
    var out: std.ArrayList(Interval) = .empty;
    if (system == .glo) {
        for (set.glonass) |*g| try out.append(arena, .{ .first = glonass.adoption(g, leap), .last = until(g, leap) });
    } else {
        for (set.kepler) |*e| if (e.sat.system == system) {
            try out.append(arena, .{ .first = e.toe.addSeconds(-kepler_window_s), .last = e.toe.addSeconds(kepler_window_s) });
        };
    }
    std.mem.sort(Interval, out.items, {}, struct {
        fn earlier(_: void, a: Interval, b: Interval) bool {
            return a.first.lessThan(b.first);
        }
    }.earlier);
    var merged: usize = 0;
    for (out.items) |span| {
        if (merged > 0 and !out.items[merged - 1].last.lessThan(span.first)) {
            const last = &out.items[merged - 1].last;
            if (last.lessThan(span.last)) last.* = span.last;
            continue;
        }
        out.items[merged] = span;
        merged += 1;
    }
    return out.items[0..merged];
}

fn until(g: *const records.GlonassEphemeris, leap: civil.Leap) GpsTime {
    var moscow = g.tb.toGlonass(leap);
    moscow.ms_of_day = @min(moscow.ms_of_day + flight_after_tb_ms, 86_400_000);
    return GpsTime.fromGlonass(leap, moscow);
}

pub fn glonassStep(set: *const NavSet, g: *const records.GlonassEphemeris, leap: civil.Leap) u2 {
    const previous = glonassFlight(set, g.sat, glonass.adoption(g, leap).addMs(-1), leap) orelse return 0;
    const q = &set.glonass[previous];
    return switch (@divFloor(g.tb.baseMs(.glo, leap) - q.tb.baseMs(.glo, leap), core.time.ms_per_minute)) {
        30 => 0b01,
        45 => 0b10,
        60 => 0b11,
        else => 0,
    };
}

fn transmission(e: *const records.KeplerEphemeris) ?GpsTime {
    if (e.transmitted) |at| return at;
    const lead = e.extra.transmissionLead() orelse return null;
    return e.toe.addSeconds(-lead);
}

const Candidates = struct {
    last: ?u32 = null,
    last_at: GpsTime = .epoch,
    nearest: ?u32 = null,
    nearest_dt: f64 = 0,

    fn record(self: Candidates, set: *const NavSet) ?u32 {
        if (self.last) |i| return if (healthy(&set.kepler[i])) i else null;
        return self.nearest;
    }
};

fn sourcesAt(set: *const NavSet, sat: types.SatId, t: GpsTime, leap: civil.Leap) std.EnumArray(records.NavSource, Candidates) {
    const leg_end: GpsTime = .{ .ms = bundle.plan.nextLegBoundary(sat.system, t, leap).ms };
    var sources: std.EnumArray(records.NavSource, Candidates) = .initFill(.{});
    for (set.kepler, 0..) |*e, i| {
        if (e.sat != sat) continue;
        const dt = @abs(t.secondsSince(e.toe));
        if (dt > kepler_window_s) continue;
        const c = sources.getPtr(e.source());
        if (transmission(e)) |at| {
            if (!at.lessThan(leg_end)) continue;
            if (c.last) |last| {
                if (at.lessThan(c.last_at) or (at.eql(c.last_at) and !recordBefore(e, &set.kepler[last]))) continue;
            }
            c.last = @intCast(i);
            c.last_at = at;
        } else if (healthy(e) and (c.nearest == null or dt < c.nearest_dt or
            (dt == c.nearest_dt and recordBefore(e, &set.kepler[c.nearest.?]))))
        {
            c.nearest = @intCast(i);
            c.nearest_dt = dt;
        }
    }
    return sources;
}
