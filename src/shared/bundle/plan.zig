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
const d1d2 = gnss.bds.d1d2;

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

pub const Binding = struct {
    reference: Ref,
    group_delay: records.GroupDelays = .{},
    attributes: gnss.reference.Attributes = .{},
    glonass_p1: ?u2 = null,
    air: []const gnss.air.Row,

    pub fn kepler(self: *const Binding, set: *const navigation.NavSet) ?gnss.reference.Kepler {
        return switch (self.reference) {
            .kepler => |k| .{ .record = &set.kepler[k], .group_delay = &self.group_delay, .attributes = &self.attributes },
            .glonass => null,
        };
    }
};

pub const Leg = struct { from_ms: u64, binding: ?Binding };

pub const Interval = struct { first: GpsTime, last: GpsTime };

pub const D1d2Entry = struct {
    sat: types.SatId,
    from_ms: u64,
    record: u32,
    interval: d1d2.Interval,
    result: d1d2.Preparation,
};

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

fn validLegs(legs: []const Leg, sat: types.SatId, set: *const navigation.NavSet, start: GpsTime, span_ms: u64, leap: Leap) ?[]const u8 {
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
        if (gnss.plausible.groupDelays(&binding.group_delay) != null) return "a leg's group delay is outside its ICD field";
        for (std.enums.values(records.NavSource)) |source| {
            if (binding.attributes.get(source) != null and source.system() != sat.system) return "a leg's message attributes belong to another source";
        }
        switch (ref) {
            .kepler => |k| {
                if (sat.system == .glo or k >= set.kepler.len) return "a leg's record is not a Keplerian record of the pool";
                if (!std.meta.eql(set.kepler[k].sat, sat)) return "a leg's Keplerian record belongs to another satellite";
                if (binding.glonass_p1 != null) return "a Keplerian leg carries a GLONASS P1 word";
                for (std.enums.values(records.GroupDelayTerm)) |term| {
                    if (set.kepler[k].group_delay.get(term)) |value| {
                        if (binding.group_delay.get(term) != value) return "a leg replaces a group delay declared by its reference";
                    }
                }
            },
            .glonass => |k| {
                if (sat.system != .glo or k >= set.glonass.len) return "a leg's record is not a GLONASS record of the pool";
                if (!std.meta.eql(set.glonass[k].sat, sat)) return "a leg's GLONASS record belongs to another satellite";
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
    d1d2: []const D1d2Entry = &.{},
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

    pub fn validate(self: *const Plan, set: *const navigation.NavSet, config: *const scenario.Scenario) ?[]const u8 {
        if (self.timelines.len != satellite_count) return "the plan does not carry one timeline per satellite";
        if (self.scales.contains(.gps)) return "the plan declares a time scale for GPS";
        if (!self.leap.valid()) return "the leap schedule contradicts the built-in history, or its change exceeds one second or is not at UTC midnight";

        for (self.timelines, 0..) |timeline, i| {
            if (!timeline.sat.valid() or slot(timeline.sat) != i) return "the timelines are not in the canonical satellite order";
            if (validLegs(timeline.legs, timeline.sat, set, self.start, self.span_ms, self.leap)) |why| return why;
        }

        var prepared_index: usize = 0;
        if (config.samples != null and config.carries(.d1d2)) {
            for (self.timelines) |timeline| {
                if (!gnss.allocation.transmitsFamily(timeline.sat, .d1d2, self.start)) continue;
                for (timeline.legs, 0..) |*leg, i| {
                    const binding = if (leg.binding) |*b| b else continue;
                    const reference = binding.kepler(set) orelse continue;
                    const interval = self.legInterval(timeline.legs, i);
                    if (prepared_index == self.d1d2.len) return "the plan omits a D1/D2 preparation";
                    const entry = &self.d1d2[prepared_index];
                    if (!std.meta.eql(entry.sat, timeline.sat) or
                        entry.from_ms != leg.from_ms or
                        entry.record != binding.reference.kepler)
                    {
                        return "the D1/D2 preparations are not in satellite and leg order";
                    }
                    if (!entry.interval.first.eql(interval.first) or !entry.interval.last.eql(interval.last)) {
                        return "a D1/D2 preparation covers another service interval";
                    }
                    if (entry.result == .ready and !entry.result.ready.valid(reference)) return "a D1/D2 preparation has invalid broadcast parameters";
                    prepared_index += 1;
                }
            }
        }
        if (prepared_index != self.d1d2.len) return "the plan carries an unused D1/D2 preparation";

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

    pub fn d1d2Leg(self: *const Plan, sat: types.SatId, from_ms: u64) ?*const D1d2Entry {
        var first: usize = 0;
        var end = self.d1d2.len;
        while (first < end) {
            const middle = first + (end - first) / 2;
            const entry = &self.d1d2[middle];
            if (std.meta.eql(entry.sat, sat) and entry.from_ms == from_ms) return entry;
            if (slot(entry.sat) < slot(sat) or (std.meta.eql(entry.sat, sat) and entry.from_ms < from_ms)) {
                first = middle + 1;
            } else {
                end = middle;
            }
        }
        return null;
    }

    pub fn d1d2At(self: *const Plan, sat: types.SatId, t: GpsTime) ?*const gnss.bds.d1d2.Prepared {
        const leg = self.legAt(sat, t) orelse return null;
        if (leg.binding == null) return null;
        const entry = self.d1d2Leg(sat, leg.from_ms) orelse return null;
        return if (entry.result == .ready) &entry.result.ready else null;
    }

    pub fn legInterval(self: *const Plan, legs: []const Leg, index: usize) Interval {
        const until_ms = if (index + 1 < legs.len) legs[index + 1].from_ms else self.span_ms;
        return .{ .first = self.start.addMs(@intCast(legs[index].from_ms)), .last = self.start.addMs(@intCast(until_ms)) };
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
};
