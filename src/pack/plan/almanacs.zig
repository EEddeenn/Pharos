const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const types = core.types;
const time = core.time;
const civil = core.civil;
const records = gnss.records;
const NavSet = @import("shared").bundle.navigation.NavSet;
const kepler = gnss.almanac;
const glonass = gnss.glonass.almanac;

const GpsTime = time.GpsTime;
const KeplerEphemeris = records.KeplerEphemeris;
const KeplerAlmanac = records.KeplerAlmanac;
const GlonassEphemeris = records.GlonassEphemeris;
const GlonassAlmanac = records.GlonassAlmanac;

const Error = error{OutOfMemory};

fn nearest(set: *const NavSet, sat: types.SatId, t: GpsTime, bits: u9) ?*const KeplerEphemeris {
    var best: ?*const KeplerEphemeris = null;
    var best_healthy = false;
    var best_dt: f64 = 0;
    for (set.kepler) |*e| {
        if (e.sat != sat or e.extra.almanacHealthBits() & bits == 0) continue;
        const ok = e.extra.almanacHealth() == 0;
        const dt = @abs(t.secondsSince(e.toe));
        if (best == null or (ok and !best_healthy) or (ok == best_healthy and dt <= best_dt)) {
            best = e;
            best_healthy = ok;
            best_dt = dt;
        }
    }
    return best;
}

fn health(set: *const NavSet, sat: types.SatId, t: GpsTime) u9 {
    var word: u9 = 0;
    var open: u9 = gnss.health.almanac_health_all;
    while (nearest(set, sat, t, open)) |e| {
        const bits = e.extra.almanacHealthBits() & open;
        word |= e.extra.almanacHealth() & bits;
        open &= ~bits;
    }
    return word;
}

fn nearestGlonass(set: *const NavSet, sat: types.SatId, t: GpsTime) ?*const GlonassEphemeris {
    var best: ?*const GlonassEphemeris = null;
    var best_dt: f64 = 0;
    for (set.glonass) |*g| {
        if (g.sat != sat) continue;
        const dt = @abs(t.secondsSince(g.tb));
        if (dt > glonass.max_span_s) continue;
        if (best == null or (g.health and !best.?.health) or (g.health == best.?.health and dt <= best_dt)) {
            best = g;
            best_dt = dt;
        }
    }
    return best;
}

fn hasSat(list: []const KeplerAlmanac, sat: types.SatId) bool {
    for (list) |a| if (a.sat == sat) return true;
    return false;
}

pub fn complete(arena: std.mem.Allocator, set: *const NavSet, file_almanacs: []const records.Almanac, scale: time.WeekScale, t: GpsTime) Error![]const KeplerAlmanac {
    const system: types.System = switch (scale) {
        .gps => .gps,
        .gal => .gal,
        .bds => .bds,
    };
    var out: std.ArrayList(KeplerAlmanac) = .empty;
    var toa: ?GpsTime = null;
    for (file_almanacs) |a| switch (a) {
        .kepler => |k| if (k.sat.system == system) {
            try out.append(arena, k);
            if (toa == null) toa = k.toa;
        },
        .glonass => {},
    };
    const common = toa orelse gnss.almanac_reference.gridTime(scale, t);
    var sats = system.satellites();
    while (sats.next()) |sat| {
        if (hasSat(out.items, sat)) continue;
        const record = nearest(set, sat, t, gnss.health.almanac_health_all) orelse continue;
        if (kepler.fromEphemeris(record, common)) |a| {
            var alm = a;
            alm.health = health(set, sat, t);
            try out.append(arena, alm);
        }
    }
    return out.items;
}

pub fn completeGlonass(arena: std.mem.Allocator, set: *const NavSet, file_almanacs: []const records.Almanac, t: GpsTime, leap: civil.Leap) Error![]const GlonassAlmanac {
    var out: std.ArrayList(GlonassAlmanac) = .empty;
    const Day = struct { n4: u5, na: u16 };
    var day: ?Day = null;
    for (file_almanacs) |a| switch (a) {
        .glonass => |g| {
            try out.append(arena, g);
            if (day == null) day = .{ .n4 = g.n4, .na = g.na };
        },
        .kepler => {},
    };
    const ref: Day = day orelse blk: {
        const g = t.toGlonass(leap);
        if (g.n4 < 1 or g.n4 > 31) return out.items;
        break :blk .{ .n4 = @intCast(g.n4), .na = g.nt };
    };
    var slots = types.System.glo.satellites();
    while (slots.next()) |sat| {
        var known = false;
        for (out.items) |a| known = known or a.sat == sat;
        if (known) continue;
        const first = nearestGlonass(set, sat, t) orelse continue;
        var path = glonass.Path.init(first);
        const node = glonass.nodeEstimate(&path, t) orelse t;
        const best = nearestGlonass(set, sat, node) orelse first;
        if (glonass.fromEphemeris(best, ref.n4, ref.na, leap)) |a| try out.append(arena, a);
    }
    return out.items;
}
