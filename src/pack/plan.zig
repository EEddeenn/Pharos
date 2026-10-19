const std = @import("std");
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
const Timeline = bundle.plan.Timeline;
pub const select = @import("plan/select.zig");
const resolve = @import("plan/resolve.zig");
const air = @import("plan/air.zig");
const contents = @import("plan/contents.zig");
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

fn legs(arena: std.mem.Allocator, set: *const NavSet, sat: types.SatId, carried: *const gnss.payload.Carried, signals: std.EnumSet(types.Signal), families: std.EnumSet(types.NavFamily), times: []const GpsTime, span_ms: u64, leap: civil.Leap) std.mem.Allocator.Error![]const Leg {
    var out: std.ArrayList(Leg) = .empty;
    var resolved: std.ArrayList(?resolve.Resolved) = .empty;
    var last: ?resolve.Resolved = null;
    for (times, 0..) |t, i| {
        const r = if (select.reference(set, sat, t, carried, signals, leap)) |chosen| resolve.binding(set, chosen, t, leap) else null;
        if (i == 0 or !sameBinding(r, last)) {
            try out.append(arena, .{ .from_ms = @intCast(t.ms - times[0].ms), .binding = null });
            try resolved.append(arena, r);
        }
        last = r;
    }
    for (out.items, resolved.items, 0..) |*leg, *entry, i| {
        const r = if (entry.*) |*r| r else continue;
        const until_ms = if (i + 1 < out.items.len) out.items[i + 1].from_ms else span_ms;
        const interval: gnss.bds.d1d2.Interval = .{ .first = times[0].addMs(@intCast(leg.from_ms)), .last = times[0].addMs(@intCast(until_ms)) };
        leg.binding = .{
            .reference = r.reference,
            .group_delay = r.group_delay,
            .air = try air.rows(arena, set, sat, r, carried),
            .contents = try contents.prepare(arena, set, r, families, interval, leap),
        };
    }
    return out.items;
}

fn sameBinding(a: ?resolve.Resolved, b: ?resolve.Resolved) bool {
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

const transmits_nothing: gnss.payload.Carried = .initFill(null);

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
                if (select.reference(&own, sat, t, &transmits_nothing, .empty, leap) != null) flying.insert(sat);
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
    const payload = gnss.payload.at(s.start);
    const needed = contents.needed(s, set, &payload);
    for (types.System.all) |system| {
        const times = try sampleTimes(arena, s.start, span_ms, system, leap);
        var sats = system.satellites();
        while (sats.next()) |sat| {
            const signals = s.signals.intersectWith(payload.transmitted(sat));
            timelines[bundle.plan.slot(sat)] = .{ .sat = sat, .legs = try legs(arena, set, sat, payload.of(sat), signals, contents.of(needed, &payload, sat), times, span_ms, leap) };
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
    const listed = gnss.payload.at(s.start).families(s.signals);
    for (p.timelines) |timeline| {
        for (std.enums.values(types.NavFamily)) |family| {
            if (!listed.contains(family)) continue;
            for (timeline.legs) |*leg| {
                const binding = if (leg.binding) |*binding| binding else continue;
                const reference = binding.kepler(set) orelse continue;
                if (reference.record.source().family() == family) continue;
                const unfit = (binding.content(family) orelse continue).unfit() orelse continue;
                switch (unfit) {
                    .field, .health => try warnRecord(reference.record, family, unfit, diags),
                    .record, .fit => {},
                }
            }
        }
    }
}

pub fn warnAssumed(s: *const model.Scenario, set: *const NavSet, p: *const Plan, run_ms: u64, diags: *Diagnostics) std.mem.Allocator.Error!void {
    var assumed: [bundle.plan.satellite_count]std.EnumSet(types.Signal) = @splat(.empty);
    var any = false;
    for (p.timelines, &assumed) |timeline, *signals| {
        if (s.mask_out.get(timeline.sat.system).contains(timeline.sat)) continue;
        for (timeline.legs) |*leg| {
            if (leg.from_ms >= run_ms) break;
            const binding = if (leg.binding) |*binding| binding else continue;
            if (set.precise) |product| if (!provider.productServes(product, timeline.sat, p.start.addMs(@intCast(leg.from_ms)), p.leap)) continue;
            var flies = false;
            var listed = s.signals.iterator();
            while (listed.next()) |signal| {
                if (signal.system() != timeline.sat.system) continue;
                const row = binding.air[gnss.spec.slot(signal)];
                if (row.status != .on_air) continue;
                flies = true;
                if (row.origin == .assumed) signals.insert(signal);
            }
            const clock_ref = set.clockReference(timeline.sat.system);
            if (set.precise == null or !flies or clock_ref == .p1p2) continue;
            // The precise clock shift moves every signal of the satellite: its pair's terms count, listed or not. P1P2's
            // shift is 0 and reads none.
            for (clock_ref.pair()) |signal| {
                if (binding.air[gnss.spec.slot(signal)].origin == .assumed) signals.insert(signal);
            }
        }
        any = any or signals.count() != 0;
    }
    if (any) try diags.warn(.group_delay_assumed, "ephemeris", "no record flown gives the group delay of {f}: each is taken as 0 s, in the signals and in a precise product's clock shift", .{Assumed{ .timelines = p.timelines, .signals = &assumed }});
}

const Assumed = struct {
    timelines: []const Timeline,
    signals: []const std.EnumSet(types.Signal),

    pub fn format(self: Assumed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        for (self.timelines, self.signals) |timeline, signals| {
            var it = signals.iterator();
            while (it.next()) |signal| {
                try w.print("{s}{f}", .{ if (first) "" else ", ", types.ChannelKey.init(timeline.sat, signal) });
                first = false;
            }
        }
    }
};

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

fn warnRecord(e: *const records.KeplerEphemeris, family: types.NavFamily, unfit: gnss.content.Unfit, diags: *Diagnostics) std.mem.Allocator.Error!void {
    const head = .{ e.sat, e.source().rinexName(e.sat), e.toc.printed(null) };
    const tail = sourceOf(family).rinexName(e.sat);
    switch (unfit) {
        .field => |name| try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: {s} outside its {s} field, sent there as unavailable while it is selected", head ++ .{ name, tail }),
        .health => |signals| try diags.warn(.unfit_record, "ephemeris", "{f} {s} record of {f}: it declares no {s} signal health for {s}, sent there as unavailable while it is selected", head ++ .{ signals, tail }),
        .record, .fit => unreachable,
    }
}

fn sourceOf(family: types.NavFamily) records.NavSource {
    return switch (family) {
        inline .lnav, .cnav, .cnav2, .inav, .fnav, .d1d2, .bcnav1, .bcnav2, .bcnav3 => |f| @field(records.NavSource, @tagName(f)),
        .cnav_has, .ppp_b2b, .gnav => unreachable,
    };
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
            try diags.warn(.no_record, "ephemeris", "no {s} satellite flies a listed signal at the run start, {f}: its signals carry nothing until one does", .{ name, at });
        } else {
            // Whole milliseconds, so every digit, as an integer is written.
            try diags.warn(.no_record, "ephemeris", "no {s} satellite flies a listed signal from {f}, {d} s into the run", .{ name, at, @as(f64, @floatFromInt(covered)) / 1000 });
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
        for (binding.air) |row| if (row.declared) |k| {
            used_kepler[k] = true;
        };
    }
}

fn remapped(arena: std.mem.Allocator, old: []const Leg, map_kepler: []const u32, map_glonass: []const u32) std.mem.Allocator.Error![]const Leg {
    const new = try arena.alloc(Leg, old.len);
    for (new, old) |*n, leg| {
        n.* = leg;
        const binding = if (n.binding) |*binding| binding else continue;
        binding.reference = switch (binding.reference) {
            .kepler => |k| .{ .kepler = map_kepler[k] },
            .glonass => |k| .{ .glonass = map_glonass[k] },
        };
        const rows = try arena.dupe(gnss.air.Row, binding.air);
        for (rows) |*row| if (row.declared) |k| {
            row.declared = map_kepler[k];
        };
        binding.air = rows;
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
