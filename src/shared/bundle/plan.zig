const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const navigation = @import("navigation.zig");
const scenario = @import("scenario.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const ClockPoly = core.clock.Poly;
const Leap = core.civil.Leap;
const records = gnss.records;
const Content = gnss.content.Content;

pub const grid_ms: i64 = 60_000;

const superframe_ms: i64 = 150_000;

pub fn legBoundary(system: types.System, t: GpsTime, leap: Leap) bool {
    return switch (system) {
        .glo => @mod(t.baseMs(.glo, leap), superframe_ms) == 0,
        .gps, .gal, .bds => @mod(t.ms, grid_ms) == 0,
    };
}

pub fn nextLegBoundary(system: types.System, t: GpsTime, leap: Leap) GpsTime {
    const ms = switch (system) {
        .glo => core.civil.nextMoscowGrid(leap, t.ms, superframe_ms),
        .gps, .gal, .bds => (@divFloor(t.ms, grid_ms) + 1) * grid_ms,
    };
    return .{ .ms = ms, .sub_ms = t.sub_ms };
}

pub const Ref = union(enum) { kepler: u32, glonass: u32 };

/// What a satellite flies on a leg: its reference record, the group delays the leg resolves, one row per signal of its
/// system, and one content per family it needs, in the families' order.
pub const Binding = struct {
    reference: Ref,
    group_delay: records.GroupDelays = .{},
    air: []const gnss.air.Row,
    contents: []const Content = &.{},

    pub fn kepler(self: *const Binding, set: *const navigation.NavSet) ?gnss.reference.Kepler {
        return switch (self.reference) {
            .kepler => |k| .{ .record = &set.kepler[k], .group_delay = &self.group_delay },
            .glonass => null,
        };
    }

    pub fn content(self: *const Binding, family: types.NavFamily) ?*const Content {
        for (self.contents) |*c| if (std.meta.activeTag(c.*) == family) return c;
        return null;
    }
};

pub const Leg = struct { from_ms: u64, binding: ?Binding };

pub const Interval = struct { first: GpsTime, last: GpsTime };

pub const Timeline = struct {
    sat: types.SatId,
    legs: []const Leg,
};

const Almanacs = struct {
    gps: []const records.KeplerAlmanac = &.{},
    galileo: []const records.KeplerAlmanac = &.{},
    bds: []const records.KeplerAlmanac = &.{},
    glonass: []const records.GlonassAlmanac = &.{},
};

pub const satellite_count = blk: {
    var n: usize = 0;
    for (types.System.all) |s| n += s.capacity();
    break :blk n;
};

const first_slot = blk: {
    var out: std.EnumArray(types.System, usize) = undefined;
    var n: usize = 0;
    for (types.System.all) |s| {
        out.set(s, n);
        n += s.capacity();
    }
    break :blk out;
};

pub fn slot(sat: types.SatId) usize {
    std.debug.assert(sat.valid());
    return first_slot.get(sat.system) + sat.index;
}

fn validLegs(legs: []const Leg, sat: types.SatId, set: *const navigation.NavSet, payload: *const gnss.payload.Payload, start: GpsTime, span_ms: u64, leap: Leap) ?[]const u8 {
    var last: ?u64 = null;
    for (legs) |leg| {
        if (leg.from_ms > span_ms) return "a leg starts past the plan's span";
        if (last) |previous| {
            if (leg.from_ms <= previous) return "the legs of a satellite are not in order";
            if (!legBoundary(sat.system, .{ .ms = start.ms + @as(i64, @intCast(leg.from_ms)) }, leap)) return "a leg does not start on a leg boundary of its system";
        }
        last = leg.from_ms;
        const binding = leg.binding orelse continue;
        const ref = binding.reference;
        if (binding.air.len != gnss.spec.signalCount(sat.system)) return "a leg does not carry one answer per signal of its system";
        for (binding.air) |row| if (row.declared) |k| {
            if (ref != .kepler or k >= set.kepler.len or set.kepler[k].sat != sat) return "a signal's health is declared by no Keplerian record of its satellite";
        };
        if (gnss.plausible.groupDelays(&binding.group_delay) != null) return "a leg's group delay is outside its ICD field";
        var previous: ?types.NavFamily = null;
        for (binding.contents) |*content| {
            const family = std.meta.activeTag(content.*);
            if (previous) |p| if (@backingInt(family) <= @backingInt(p)) return "a leg's contents are not one per family, in the families' order";
            previous = family;
            if (!payload.carries(sat, family)) return "a leg carries a content of a family its satellite does not carry";
            if (!content.valid(sat, leap)) return "a leg's content does not fit its family's messages";
        }
        switch (ref) {
            .kepler => |k| {
                if (sat.system == .glo or k >= set.kepler.len) return "a leg's record is not a Keplerian record of the pool";
                if (!std.meta.eql(set.kepler[k].sat, sat)) return "a leg's Keplerian record belongs to another satellite";
                for (std.enums.values(records.GroupDelayTerm)) |term| {
                    if (set.kepler[k].group_delay.get(term)) |value| {
                        if (binding.group_delay.get(term) != value) return "a leg replaces a group delay declared by its reference";
                    }
                }
            },
            .glonass => |k| {
                if (sat.system != .glo or k >= set.glonass.len) return "a leg's record is not a GLONASS record of the pool";
                if (!std.meta.eql(set.glonass[k].sat, sat)) return "a leg's GLONASS record belongs to another satellite";
                if (set.glonass[k].delta_tau_n) |own| {
                    if (binding.group_delay.get(.delta_tau_n) != own) return "a leg replaces a group delay declared by its reference";
                }
            },
        }
    }
    return null;
}

fn flies(leg: Leg, sat: types.SatId, signals: std.EnumSet(types.Signal)) bool {
    const binding = leg.binding orelse return false;
    var it = signals.iterator();
    while (it.next()) |signal| {
        if (signal.system() == sat.system and binding.air[gnss.spec.slot(signal)].status == .on_air) return true;
    }
    return false;
}

pub const Plan = struct {
    start: GpsTime,
    span_ms: u64,
    timelines: []const Timeline,
    almanacs: Almanacs,
    scales: std.EnumMap(types.System, ClockPoly),
    leap: Leap,

    pub fn scaleOffset(self: *const Plan, system: types.System, t: GpsTime) f64 {
        return if (self.scales.get(system)) |p| p.bias(t) else 0;
    }

    pub fn coveredMs(self: *const Plan, s: *const scenario.Scenario, system: ?types.System) u64 {
        var cursor: [satellite_count]usize = @splat(0);
        var covered: u64 = 0;
        var moved = true;
        while (moved) {
            moved = false;
            for (self.timelines, &cursor) |timeline, *at| {
                if (system) |only| if (timeline.sat.system != only) continue;
                if (!s.transmitsListed(timeline.sat)) continue;
                const all = timeline.legs;
                while (at.* < all.len and all[at.*].from_ms <= covered) : (at.* += 1) {
                    const until = if (at.* + 1 < all.len) all[at.* + 1].from_ms else self.span_ms;
                    if (flies(all[at.*], timeline.sat, s.signals) and until > covered) {
                        covered = until;
                        moved = true;
                    }
                }
            }
        }
        return @min(covered, self.span_ms);
    }

    pub fn fliesAt(self: *const Plan, s: *const scenario.Scenario, t: GpsTime) bool {
        for (self.timelines) |timeline| {
            if (!s.transmitsListed(timeline.sat)) continue;
            const leg = self.legAt(timeline.sat, t) orelse continue;
            if (flies(leg.*, timeline.sat, s.signals)) return true;
        }
        return false;
    }

    pub fn validate(self: *const Plan, set: *const navigation.NavSet) ?[]const u8 {
        if (self.timelines.len != satellite_count) return "the plan does not carry one timeline per satellite";
        if (self.scales.contains(.gps)) return "the plan declares a time scale for GPS";
        if (!self.leap.valid()) return "the leap schedule contradicts the built-in history, or its change exceeds one second or is not at UTC midnight";

        const payload = gnss.payload.at(self.start);
        for (self.timelines, 0..) |timeline, i| {
            if (!timeline.sat.valid() or slot(timeline.sat) != i) return "the timelines are not in the canonical satellite order";
            if (validLegs(timeline.legs, timeline.sat, set, &payload, self.start, self.span_ms, self.leap)) |why| return why;
        }

        for (self.almanacs.gps) |a| if (a.sat.system != .gps or !a.sat.valid()) return "a GPS almanac names another system's satellite";
        for (self.almanacs.galileo) |a| if (a.sat.system != .gal or !a.sat.valid()) return "a Galileo almanac names another system's satellite";
        for (self.almanacs.bds) |a| if (a.sat.system != .bds or !a.sat.valid()) return "a BDS almanac names another system's satellite";
        for (self.almanacs.glonass) |a| {
            if (a.sat.system != .glo or !a.sat.valid()) return "a GLONASS almanac names another system's satellite";
            if (!a.freq.valid()) return "a GLONASS almanac's frequency number is outside its range";
            if (a.na < 1 or a.na > core.civil.glonass_cycle_days or a.n4 < 1) return "a GLONASS almanac's day NA or interval N4 is outside its range";
        }
        return null;
    }

    fn legAt(self: *const Plan, sat: types.SatId, t: GpsTime) ?*const Leg {
        if (t.lessThan(self.start)) return null;
        if (self.start.addMs(@intCast(self.span_ms)).lessThan(t)) return null;

        var found: ?*const Leg = null;
        for (self.timelines[slot(sat)].legs) |*leg| {
            if (t.lessThan(self.start.addMs(@intCast(leg.from_ms)))) break;
            found = leg;
        }
        return found;
    }

    pub fn bindingAt(self: *const Plan, sat: types.SatId, t: GpsTime) ?*const Binding {
        const leg = self.legAt(sat, t) orelse return null;
        return if (leg.binding) |*binding| binding else null;
    }

    pub fn recordAt(self: *const Plan, sat: types.SatId, t: GpsTime) ?Ref {
        const binding = self.bindingAt(sat, t) orelse return null;
        return binding.reference;
    }

    /// What a family carries for a satellite on the leg in force at `t`.
    pub fn contentAt(self: *const Plan, sat: types.SatId, family: types.NavFamily, t: GpsTime) ?*const Content {
        const binding = self.bindingAt(sat, t) orelse return null;
        return binding.content(family);
    }
};
