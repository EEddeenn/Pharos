const std = @import("std");
pub const d1d2 = @import("plan/d1d2.zig");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const Diagnostics = @import("shared").core.diagnostics.Diagnostics;
const provider = @import("shared").track.provider;
const types = core.types;
const civil = core.civil;
const GpsTime = core.time.GpsTime;
const records = gnss.records;
const NavSet = bundle.navigation.NavSet;
const Product = bundle.precise.Product;
const model = bundle.scenario;
const Plan = bundle.plan.Plan;
const Leg = bundle.plan.Leg;
const Binding = bundle.plan.Binding;
const Timeline = bundle.plan.Timeline;
pub const select = @import("plan/select.zig");
const resolve = @import("plan/resolve.zig");
const air = @import("plan/air.zig");
pub const almanacs = @import("plan/almanacs.zig");

const Error = std.mem.Allocator.Error || error{LegBoundaryStalls};

const product_trim_slack_samples = 3;

const tail_ms: u64 = bundle.plan.grid_ms;

fn sampleTimes(arena: std.mem.Allocator, start: GpsTime, span_ms: u64, system: types.System, leap: civil.Leap) Error![]const GpsTime {
    var out: std.ArrayList(GpsTime) = .empty;
    try out.append(arena, start);
    const end_ms = start.ms + @as(i64, @intCast(span_ms));
    var t = start;
    while (true) {
        const next = bundle.plan.nextLegBoundary(system, t, leap);
        if (!t.lessThan(next)) return error.LegBoundaryStalls;
        if (next.ms > end_ms) break;
        try out.append(arena, next);
        t = next;
    }
    return out.items;
}

fn legs(arena: std.mem.Allocator, set: *const NavSet, sat: types.SatId, allocated: std.EnumSet(types.Signal), signals: std.EnumSet(types.Signal), times: []const GpsTime, leap: civil.Leap) std.mem.Allocator.Error![]const Leg {
    var out: std.ArrayList(Leg) = .empty;
    var last: ?Binding = null;
    for (times, 0..) |t, i| {
        const binding = if (select.reference(set, sat, t, signals, leap)) |ref| resolve.binding(set, ref, t, leap) else null;
        if (i == 0 or !sameBinding(binding, last)) {
            var leg: Leg = .{ .from_ms = @intCast(t.ms - times[0].ms), .binding = binding };
            if (leg.binding) |*b| b.air = try air.rows(arena, set, sat, b, allocated);
            try out.append(arena, leg);
        }
        last = binding;
    }
    return out.items;
}

fn sameBinding(a: ?Binding, b: ?Binding) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    if (!std.meta.eql(left.reference, right.reference) or left.glonass_p1 != right.glonass_p1) return false;
    for (std.enums.values(records.GroupDelayTerm)) |term| {
        if (left.group_delay.get(term) != right.group_delay.get(term)) return false;
    }
    for (std.enums.values(records.NavSource)) |source| {
        if (!std.meta.eql(left.attributes.get(source), right.attributes.get(source))) return false;
    }
    return true;
}

pub const Covered = struct { system: types.System, satellites: types.SatSet, from: GpsTime, until: GpsTime, leap_seconds: i8 };

pub fn coverage(arena: std.mem.Allocator, set: *const NavSet, leap: civil.Leap) Error![]const Covered {
    var out: std.ArrayList(Covered) = .empty;
    for (types.System.all) |system| {
        var grid: std.ArrayList(GpsTime) = .empty;
        for (try select.reaches(arena, set, system, leap)) |reach| {
            const first = if (bundle.plan.legBoundary(system, reach.first, leap)) reach.first else bundle.plan.nextLegBoundary(system, reach.first, leap);
            if (reach.last.lessThan(first)) continue;
            for (try sampleTimes(arena, first, @intCast(reach.last.ms - first.ms), system, leap)) |t| {
                if (grid.items.len == 0 or grid.items[grid.items.len - 1].lessThan(t)) try grid.append(arena, t);
            }
        }
        const times = grid.items;
        const present = try arena.alloc(types.SatSet, times.len);
        @memset(present, .empty);
        var sats = system.satellites();
        while (sats.next()) |sat| {
            const own = try ownRecords(arena, set, sat);
            if (own.kepler.len == 0 and own.glonass.len == 0) continue;
            for (times, present) |t, *flying| {
                if (select.reference(&own, sat, t, .empty, leap) != null) flying.insert(sat);
            }
        }
        var i: usize = 0;
        while (i < times.len) {
            if (present[i].count() == 0) {
                i += 1;
                continue;
            }
            const from = times[i];
            var satellites = present[i];
            i += 1;
            while (i < times.len and present[i].count() != 0) : (i += 1) {
                const expected = bundle.plan.nextLegBoundary(system, times[i - 1], leap);
                if (!times[i].eql(expected)) break;
                satellites.merge(present[i]);
            }
            try out.append(arena, .{
                .system = system,
                .satellites = satellites,
                .from = from,
                .until = bundle.plan.nextLegBoundary(system, times[i - 1], leap),
                .leap_seconds = leap.atMs(from.ms).count,
            });
        }
    }
    return out.items;
}

fn ownRecords(arena: std.mem.Allocator, set: *const NavSet, sat: types.SatId) std.mem.Allocator.Error!NavSet {
    var kepler: std.ArrayList(records.KeplerEphemeris) = .empty;
    for (set.kepler) |e| if (e.sat == sat) try kepler.append(arena, e);
    var glonass: std.ArrayList(records.GlonassEphemeris) = .empty;
    for (set.glonass) |g| if (g.sat == sat) try glonass.append(arena, g);
    return .{ .kepler = kepler.items, .glonass = glonass.items };
}

pub fn build(arena: std.mem.Allocator, s: *const model.Scenario, set: *const NavSet, file_almanacs: []const records.Almanac, run_ms: u64, leap: civil.Leap) Error!Plan {
    const span_ms = run_ms + tail_ms;
    const timelines = try arena.alloc(Timeline, bundle.plan.satellite_count);
    const allocation = gnss.allocation.at(s.start);
    for (types.System.all) |system| {
        const times = try sampleTimes(arena, s.start, span_ms, system, leap);
        var sats = system.satellites();
        while (sats.next()) |sat| {
            const allocated = allocation.signals[sat.key()];
            timelines[bundle.plan.slot(sat)] = .{ .sat = sat, .legs = try legs(arena, set, sat, allocated, s.signals.intersectWith(allocated), times, leap) };
        }
    }
    return .{
        .start = s.start,
        .span_ms = span_ms,
        .timelines = timelines,
        .almanacs = .{
            .gps = try almanacs.complete(arena, set, file_almanacs, .gps, s.start),
            .galileo = try almanacs.complete(arena, set, file_almanacs, .gal, s.start),
            .bds = try almanacs.complete(arena, set, file_almanacs, .bds, s.start),
            .glonass = if (s.carries(.gnav)) try almanacs.completeGlonass(arena, set, file_almanacs, s.start, leap) else &.{},
        },
        .scales = scales(set, s.start),
        .leap = leap,
    };
}

fn scales(set: *const NavSet, start: GpsTime) std.EnumMap(types.System, core.clock.Poly) {
    var out: std.EnumMap(types.System, core.clock.Poly) = .{};
    for (types.System.all) |system| {
        const kind = gnss.auxiliary.gpsOffsetKind(system) orelse continue;
        const record = set.timeOffset(kind, system, start) orelse set.timeOffset(kind, .gps, start) orelse continue;
        if (record.scaleOffset(start)) |poly| out.put(system, poly);
    }
    return out;
}

pub fn warnUnfit(s: *const model.Scenario, set: *const NavSet, p: *const Plan, diags: *Diagnostics) std.mem.Allocator.Error!void {
    if (s.samples == null) return;
    const allocation = gnss.allocation.at(s.start);
    for (p.timelines) |timeline| {
        for ([_]records.NavSource{ .cnav, .cnav2, .bcnav1, .bcnav2, .bcnav3 }) |source| {
            if (!s.carries(source.family()) or !allocation.transmitsFamily(timeline.sat, source.family())) continue;
            if (source == .bcnav3 and gnss.bds.allocation.carriesPppB2b(timeline.sat.prn())) continue;
            for (timeline.legs) |*leg| {
                const binding = if (leg.binding) |*binding| binding else continue;
                const reference = binding.kepler(set) orelse continue;
                if (reference.record.source() == source) continue;
                const unfit = gnss.plausible.converted(reference, source) orelse continue;
                try warnRecord(reference.record, source, unfit, diags);
            }
        }
        if (!s.carries(.d1d2) or !allocation.transmitsFamily(timeline.sat, .d1d2)) continue;
        for (timeline.legs) |leg| {
            const k = keplerOf(leg) orelse continue;
            const e = &set.kepler[k];
            if (e.source() == .d1d2) continue;
            const prepared = p.d1d2Leg(timeline.sat, leg.from_ms) orelse continue;
            const unfit: gnss.plausible.Unfit = switch (prepared.result) {
                .unrepresentable => |failed| .{ .field = failed.name() },
                else => continue,
            };
            try warnRecord(e, .d1d2, unfit, diags);
        }
    }
}

pub fn warnClockReference(set: *const NavSet, p: *const Plan, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const product = set.precise orelse return;
    for (p.timelines) |timeline| {
        const clock_ref = set.clockReference(timeline.sat.system);
        for (timeline.legs) |*leg| {
            const binding = if (leg.binding) |*binding| binding else continue;
            const at = p.start.addMs(@intCast(leg.from_ms));
            if (!provider.productServes(product, timeline.sat, at, p.leap)) continue;
            const missing = missingClockTerm(clock_ref, binding) orelse continue;
            try diags.warn(.no_record, "ephemeris", "{f}: a record it flies carries no {s} group delay, which the {s} clock of the precise product refers to: the satellite is dark while that record is selected", .{ timeline.sat, missing.name(), clock_ref.name() });
            break;
        }
    }
}

pub fn warnUnserved(set: *const NavSet, p: *const Plan, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const product = set.precise orelse return;
    var unserved: [bundle.plan.satellite_count]types.SatId = undefined;
    var count: usize = 0;
    for (p.timelines) |timeline| {
        if (p.recordAt(timeline.sat, p.start) == null or provider.productServes(product, timeline.sat, p.start, p.leap)) continue;
        unserved[count] = timeline.sat;
        count += 1;
    }
    if (count > 0) try diags.warn(.no_record, "ephemeris", "the precise product does not serve {f} at the run start, {f}: they transmit nothing until it does", .{ Satellites{ .list = unserved[0..count] }, p.start.printed(null) });
}

const Satellites = struct {
    list: []const types.SatId,

    pub fn format(self: Satellites, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.list, 0..) |sat, i| try w.print("{s}{f}", .{ if (i == 0) "" else " ", sat });
    }
};

fn missingClockTerm(clock_ref: gnss.delay.ClockRef, binding: *const Binding) ?types.Signal {
    const pair = clock_ref.pair();
    return clock_ref.missingTerm(binding.air[gnss.spec.slot(pair[0])].given(), binding.air[gnss.spec.slot(pair[1])].given());
}

fn keplerOf(leg: bundle.plan.Leg) ?u32 {
    const binding = leg.binding orelse return null;
    return switch (binding.reference) {
        .kepler => |i| i,
        .glonass => null,
    };
}

fn warnRecord(e: *const records.KeplerEphemeris, target: records.NavSource, unfit: gnss.plausible.Unfit, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const head = .{ e.sat, e.source().rinexName(e.sat), e.toc.printed(null) };
    const tail = target.rinexName(e.sat);
    switch (unfit) {
        .field => |name| try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: {s} outside its {s} field, sent there as unavailable while it is selected", head ++ .{ name, tail }),
        .health => |signals| try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: it declares no {s} signal health for {s}, sent there as unavailable while it is selected", head ++ .{ signals, tail }),
    }
}

pub fn reportCoverage(plan: *const Plan, s: *const model.Scenario, run_ms: u64, diags: *Diagnostics) std.mem.Allocator.Error!void {
    for (types.System.all) |system| {
        var sats = system.satellites();
        const listed = while (sats.next()) |sat| {
            if (s.transmitsListed(sat)) break true;
        } else false;
        if (!listed) continue;
        const covered = plan.coveredMs(s, system);
        if (covered >= run_ms) continue;
        const t = s.start.addMs(@intCast(covered));
        const at = t.printed(null);
        const name = system.displayName();
        if (covered == 0) {
            try diags.warn(.no_record, "ephemeris", "no {s} satellite has a record at the run start, {f}: its signals carry nothing until one does", .{ name, at });
        } else {
            // Whole milliseconds, so every digit, as an integer is written.
            try diags.warn(.no_record, "ephemeris", "no {s} satellite has a record from {f}, {d} s into the run", .{ name, at, @as(f64, @floatFromInt(covered)) / 1000 });
        }
    }
}

fn markUsed(legs_of: []const Leg, used_kepler: []bool, used_glonass: []bool) void {
    for (legs_of) |leg| {
        const binding = leg.binding orelse continue;
        switch (binding.reference) {
            .kepler => |k| used_kepler[k] = true,
            .glonass => |k| used_glonass[k] = true,
        }
    }
}

fn remapped(arena: std.mem.Allocator, old: []const Leg, map_kepler: []const u32, map_glonass: []const u32) std.mem.Allocator.Error![]const Leg {
    const new = try arena.alloc(Leg, old.len);
    for (new, old) |*n, leg| {
        n.* = leg;
        if (n.binding) |*binding| binding.reference = switch (binding.reference) {
            .kepler => |k| .{ .kepler = map_kepler[k] },
            .glonass => |k| .{ .glonass = map_glonass[k] },
        };
    }
    return new;
}

pub fn setGlonassFrequencies(set: *NavSet) void {
    for (set.glonass) |g| {
        if (set.glonass_freq[g.sat.index] == null) set.glonass_freq[g.sat.index] = g.freq;
    }
}

fn kept(comptime T: type, arena: std.mem.Allocator, all: []const T, used: []const bool, map: []u32) std.mem.Allocator.Error![]T {
    const out = try arena.alloc(T, std.mem.countScalar(bool, used, true));
    var n: u32 = 0;
    for (all, used, map) |e, u, *m| if (u) {
        m.* = n;
        out[n] = e;
        n += 1;
    };
    return out;
}

pub fn trim(arena: std.mem.Allocator, set: *NavSet, plan: *Plan, product: ?*Product) std.mem.Allocator.Error!void {
    const used_kepler = try arena.alloc(bool, set.kepler.len);
    const used_glonass = try arena.alloc(bool, set.glonass.len);
    @memset(used_kepler, false);
    @memset(used_glonass, false);
    for (plan.timelines) |timeline| {
        markUsed(timeline.legs, used_kepler, used_glonass);
    }

    const map_kepler = try arena.alloc(u32, set.kepler.len);
    const kepler = try kept(records.KeplerEphemeris, arena, set.kepler, used_kepler, map_kepler);
    const map_glonass = try arena.alloc(u32, set.glonass.len);
    const glonass = try kept(records.GlonassEphemeris, arena, set.glonass, used_glonass, map_glonass);

    const timelines = try arena.alloc(Timeline, plan.timelines.len);
    for (timelines, plan.timelines) |*out, timeline| {
        out.* = .{ .sat = timeline.sat, .legs = try remapped(arena, timeline.legs, map_kepler, map_glonass) };
    }

    set.kepler = kepler;
    set.glonass = glonass;
    plan.timelines = timelines;

    if (product) |p| {
        const margin_s = @as(f64, @floatFromInt(bundle.precise.window / 2 + product_trim_slack_samples)) * p.interval_s + bundle.precise.coverage_span_s;
        p.trim(plan.start.addSeconds(-margin_s), plan.start.addMs(@intCast(plan.span_ms)).addSeconds(margin_s));
    }
}
