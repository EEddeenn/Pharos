const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const records = @import("domain/navigation/records");
const signal_payload = @import("domain/signals/payload");
const flight_plan = @import("simulation/model/flight_plan");
const select = @import("products/pack/planning/select");
const time_grid = @import("products/pack/planning/time_grid");
const GpsTime = @import("domain/time/gps").GpsTime;
const Ephemerides = records.Ephemerides;
const Error = time_grid.Error;

pub const Covered = struct { system: gnss_types.System, satellites: gnss_types.SatSet, from: GpsTime, until: GpsTime, leap_seconds: i8 };

const transmits_nothing: signal_payload.Carried = .initFill(null);

pub fn coverage(arena: std.mem.Allocator, set: *const Ephemerides, leap: civil.Leap) Error![]const Covered {
    var out: std.ArrayList(Covered) = .empty;
    for (gnss_types.System.all) |system| {
        var grid: std.ArrayList(GpsTime) = .empty;
        for (try select.reaches(arena, set, system, leap)) |reach| {
            const first = if (flight_plan.legBoundary(system, reach.first, leap)) reach.first else flight_plan.nextLegBoundary(system, reach.first, leap);
            if (reach.last.lessThan(first)) continue;
            for (try time_grid.samples(arena, first, @intCast(reach.last.ms - first.ms), system, leap)) |t| {
                if (grid.items.len == 0 or grid.items[grid.items.len - 1].lessThan(t)) try grid.append(arena, t);
            }
        }
        const times = grid.items;
        const present = try arena.alloc(gnss_types.SatSet, times.len);
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
                const expected = flight_plan.nextLegBoundary(system, times[i - 1], leap);
                if (!times[i].eql(expected)) break;
                satellites.merge(present[i]);
            }
            try out.append(arena, .{
                .system = system,
                .satellites = satellites,
                .from = from,
                .until = flight_plan.nextLegBoundary(system, times[i - 1], leap),
                .leap_seconds = leap.atMs(from.ms).count,
            });
        }
    }
    return out.items;
}

fn ownRecords(arena: std.mem.Allocator, set: *const Ephemerides, sat: gnss_types.SatId) std.mem.Allocator.Error!Ephemerides {
    var kepler: std.ArrayList(records.KeplerEphemeris) = .empty;
    for (set.kepler) |e| if (e.sat == sat) try kepler.append(arena, e);
    var glonass: std.ArrayList(records.GlonassEphemeris) = .empty;
    for (set.glonass) |g| if (g.sat == sat) try glonass.append(arena, g);
    return .{ .kepler = kepler.items, .glonass = glonass.items };
}
