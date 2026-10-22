const std = @import("std");
const civil = @import("domain/time/civil");
const configuration = @import("simulation/model/config");
const publications = @import("simulation/model/publications");
const selection = @import("simulation/model/signals");
const differential = @import("domain/messages/gps/differential");
const orbit = @import("domain/navigation/orbit/parameters");
const signal_air = @import("domain/navigation/air");
const signal_catalog = @import("domain/signals/catalog");
const gnss_types = @import("domain/gnss_types");
const ServicePlan = @import("simulation/model/services").ServicePlan;
const GpsTime = @import("domain/time/gps").GpsTime;
const ClockPoly = @import("domain/time/clock").Poly;
const Leap = civil.Leap;
const Content = @import("domain/messages/content").Content;

pub const grid_ms: i64 = 60_000;

const superframe_ms: i64 = 150_000;

pub const Ref = union(enum) { kepler: u32, glonass: u32 };

pub const Flown = union(enum) {
    kepler: orbit.Parameters,
    glonass: struct { tb: GpsTime, pos: [3]f64, vel: [3]f64, acc: [3]f64, clock: ClockPoly },
    precise: struct { delay_shift_s: f64 },
};

pub const Binding = struct {
    reference: Ref,
    flown: Flown,
    freq: ?gnss_types.FreqId,
    air: []const signal_air.Row,
    contents: []const Content = &.{},

    pub fn content(self: *const Binding, family: gnss_types.NavFamily) ?*const Content {
        for (self.contents) |*c| if (std.meta.activeTag(c.*) == family) return c;
        return null;
    }
};

pub const Leg = struct {
    from_ms: u64,
    binding: ?Binding,
    // The first display leg of this numerical binding; DC and PPP caches use that stable key.
    binding_start: usize,
};

pub const LegId = struct {
    sat: gnss_types.SatId,
    index: usize,

    pub fn eql(self: LegId, other: LegId) bool {
        return self.sat == other.sat and self.index == other.index;
    }
};

pub const Interval = struct { first: GpsTime, last: GpsTime };

pub const Timeline = struct {
    sat: gnss_types.SatId,
    legs: []const Leg,
};

pub const satellite_count = blk: {
    var n: usize = 0;
    for (gnss_types.System.all) |s| n += s.capacity();
    break :blk n;
};

pub const PreparedContents = [satellite_count][]const []const Content;

const first_slot = blk: {
    var out: std.EnumArray(gnss_types.System, usize) = undefined;
    var n: usize = 0;
    for (gnss_types.System.all) |s| {
        out.set(s, n);
        n += s.capacity();
    }
    break :blk out;
};

pub const FlightPlan = struct {
    start: GpsTime,
    spans_ms: std.EnumArray(gnss_types.System, u64),
    timelines: []const Timeline,
    scales: std.EnumMap(gnss_types.System, ClockPoly),
    leap: Leap,

    pub fn scaleOffset(self: *const FlightPlan, system: gnss_types.System, t: GpsTime) f64 {
        return if (self.scales.get(system)) |p| p.bias(t) else 0;
    }

    pub fn coveredMs(self: *const FlightPlan, s: *const configuration.Config, system: ?gnss_types.System) u64 {
        var cursor: [satellite_count]usize = @splat(0);
        var covered: u64 = 0;
        var moved = true;
        while (moved) {
            moved = false;
            for (self.timelines, &cursor) |timeline, *at| {
                if (system) |only| if (timeline.sat.system != only) continue;
                if (!selection.transmits(s.signals, s.mask_out, s.start, timeline.sat)) continue;
                const all = timeline.legs;
                while (at.* < all.len and all[at.*].from_ms <= covered) : (at.* += 1) {
                    const until = if (at.* + 1 < all.len) all[at.* + 1].from_ms else self.spans_ms.get(timeline.sat.system);
                    if (flies(all[at.*], timeline.sat, s.signals) and until > covered) {
                        covered = until;
                        moved = true;
                    }
                }
            }
        }
        const span_ms = if (system) |only| self.spans_ms.get(only) else std.mem.max(u64, &self.spans_ms.values);
        return @min(covered, span_ms);
    }

    pub fn fliesAt(self: *const FlightPlan, s: *const configuration.Config, t: GpsTime) bool {
        for (self.timelines) |timeline| {
            if (!selection.transmits(s.signals, s.mask_out, s.start, timeline.sat)) continue;
            const leg = self.legAt(timeline.sat, t) orelse continue;
            if (flies(leg.*, timeline.sat, s.signals)) return true;
        }
        return false;
    }

    pub fn legIdAt(self: *const FlightPlan, sat: gnss_types.SatId, t: GpsTime) ?LegId {
        const index = self.legIndexAt(sat, t) orelse return null;
        return .{ .sat = sat, .index = index };
    }

    pub fn bindingStartAt(self: *const FlightPlan, sat: gnss_types.SatId, t: GpsTime) ?LegId {
        const leg = self.legAt(sat, t) orelse return null;
        if (leg.binding == null) return null;
        return .{ .sat = sat, .index = leg.binding_start };
    }

    pub fn bindingAt(self: *const FlightPlan, sat: gnss_types.SatId, t: GpsTime) ?*const Binding {
        const leg = self.legAt(sat, t) orelse return null;
        return if (leg.binding) |*binding| binding else null;
    }

    pub fn recordAt(self: *const FlightPlan, sat: gnss_types.SatId, t: GpsTime) ?Ref {
        const binding = self.bindingAt(sat, t) orelse return null;
        return binding.reference;
    }

    /// What a family carries for a satellite on the leg in force at `t`.
    pub fn contentAt(self: *const FlightPlan, sat: gnss_types.SatId, family: gnss_types.NavFamily, t: GpsTime) ?*const Content {
        const binding = self.bindingAt(sat, t) orelse return null;
        return binding.content(family);
    }

    fn legIndexAt(self: *const FlightPlan, sat: gnss_types.SatId, t: GpsTime) ?usize {
        if (t.lessThan(self.start)) return null;
        if (self.start.addMs(@intCast(self.spans_ms.get(sat.system))).lessThan(t)) return null;

        const legs = self.timelines[slot(sat)].legs;
        var first: usize = 0;
        var end = legs.len;
        while (first < end) {
            const mid = first + (end - first) / 2;
            if (t.lessThan(self.start.addMs(@intCast(legs[mid].from_ms)))) {
                end = mid;
            } else first = mid + 1;
        }
        return if (first == 0) null else first - 1;
    }

    fn legAt(self: *const FlightPlan, sat: gnss_types.SatId, t: GpsTime) ?*const Leg {
        const index = self.legIndexAt(sat, t) orelse return null;
        return &self.timelines[slot(sat)].legs[index];
    }
};

pub fn spansMs(signals: std.EnumSet(gnss_types.Signal), services: ServicePlan, run_ms: u64) std.EnumArray(gnss_types.System, u64) {
    var spans: std.EnumArray(gnss_types.System, u64) = .initFill(0);
    var enabled = selection.systems(signals).iterator();
    while (enabled.next()) |system| spans.set(system, run_ms + grid_ms);
    if (services.runs(.gps_differential)) spans.set(.gps, run_ms + differential.epoch_ms + publications.lookahead_ms);
    return spans;
}

pub fn legBoundary(system: gnss_types.System, t: GpsTime, leap: Leap) bool {
    return switch (system) {
        .glo => @mod(t.baseMs(.glo, leap), superframe_ms) == 0,
        .gps, .gal, .bds => @mod(t.ms, grid_ms) == 0,
    };
}

pub fn nextLegBoundary(system: gnss_types.System, t: GpsTime, leap: Leap) GpsTime {
    const ms = switch (system) {
        .glo => civil.nextMoscowGrid(leap, t.ms, superframe_ms),
        .gps, .gal, .bds => (@divFloor(t.ms, grid_ms) + 1) * grid_ms,
    };
    return .{ .ms = ms, .sub_ms = t.sub_ms };
}

pub fn slot(sat: gnss_types.SatId) usize {
    std.debug.assert(sat.valid());
    return first_slot.get(sat.system) + sat.index;
}

fn flies(leg: Leg, sat: gnss_types.SatId, signals: std.EnumSet(gnss_types.Signal)) bool {
    const binding = leg.binding orelse return false;
    var it = signals.iterator();
    while (it.next()) |signal| {
        if (signal.system() == sat.system and binding.air[signal_catalog.slot(signal)].status == .on_air) return true;
    }
    return false;
}
