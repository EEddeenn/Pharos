const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const records = @import("domain/navigation/records");
const navigation_health = @import("domain/navigation/health");
const epoch_grid = @import("domain/navigation/almanac_epoch");
const kepler = @import("domain/navigation/almanac");
const glonass = @import("domain/navigation/almanac/glonass");
const bds_records = @import("domain/navigation/records/bds");
const field = @import("base/binary/field");
const lnav_fields = @import("domain/messages/gps/lnav/fields");
const gps_almanac = @import("domain/messages/gps/fields/almanac");
const galileo_almanac = @import("domain/messages/galileo/fields/almanac");
const d1d2 = @import("domain/messages/bds/d1d2/pages");
const bds_almanac = @import("domain/messages/bds/fields/almanac");
const gnav_fields = @import("domain/messages/glonass/gnav/fields");
const gnav_system = @import("domain/messages/glonass/gnav/system");
const prepared = @import("simulation/model/prepared_messages");
const selection = @import("simulation/model/signals");
const GpsTime = time.GpsTime;
const KeplerEphemeris = records.KeplerEphemeris;
const KeplerAlmanac = records.KeplerAlmanac;
const GlonassEphemeris = records.GlonassEphemeris;
const GlonassAlmanac = records.GlonassAlmanac;

pub const Planned = struct { stored: prepared.StoredAlmanacs, prepared: prepared.Almanacs };

pub fn prepare(arena: std.mem.Allocator, ephemerides: records.Ephemerides, supplied: []const records.Almanac, signals: std.EnumSet(gnss_types.Signal), families: std.EnumSet(gnss_types.NavFamily), start: GpsTime, leap: civil.Leap, configuration: *const [63]u3) std.mem.Allocator.Error!Planned {
    const enabled = selection.systems(signals);
    const gps_epoch = chooseEpoch(supplied, .gps, start);
    const galileo_epoch = chooseEpoch(supplied, .gal, start);
    const bds_epoch = chooseEpoch(supplied, .bds, start);
    const day: ?gnav_system.Day = if (enabled.contains(.glo)) chooseDay(supplied, start, leap) else null;
    const gps = if (enabled.contains(.gps)) try complete(arena, ephemerides.kepler, supplied, .gps, gps_epoch, families.contains(.lnav)) else Completed(KeplerAlmanac){};
    const galileo = if (enabled.contains(.gal)) try complete(arena, ephemerides.kepler, supplied, .gal, galileo_epoch, families.contains(.inav) or families.contains(.fnav)) else Completed(KeplerAlmanac){};
    const bds = if (enabled.contains(.bds)) try complete(arena, ephemerides.kepler, supplied, .bds, bds_epoch, families.contains(.d1d2)) else Completed(KeplerAlmanac){};
    const glonass_records = if (day) |value| try completeGlonass(arena, ephemerides.glonass, supplied, value, leap, families.contains(.gnav)) else Completed(GlonassAlmanac){};
    var stored: prepared.StoredAlmanacs = .{
        .gps = gps.records,
        .galileo = galileo.records,
        .bds = bds.records,
        .glonass = glonass_records.records,
        .gps_epoch = gps_epoch,
        .galileo_epoch = galileo_epoch,
        .bds_epoch = bds_epoch,
        .glonass_day = day,
        .selected = .{ .lnav = gps.native, .galileo = galileo.native, .d1d2 = bds.native, .gnav = glonass_records.native },
    };
    if (families.contains(.cnav) or families.contains(.cnav2)) for (stored.gps) |a| {
        if (gps_almanac.representable(a)) stored.selected.cnav.insert(a.sat);
    };
    if (families.contains(.bcnav1) or families.contains(.bcnav2) or families.contains(.bcnav3)) for (stored.bds) |a| {
        if (bds_almanac.Slot.representable(a)) stored.selected.bcnav.insert(a.sat);
    };
    return .{ .stored = stored, .prepared = prepared.Almanacs.init(&stored, configuration) };
}

fn chooseEpoch(supplied: []const records.Almanac, system: gnss_types.System, start: GpsTime) GpsTime {
    const scale: time.WeekScale = switch (system) {
        .gps => .gps,
        .gal => .gal,
        .bds => .bds,
        .glo => unreachable,
    };
    const step: u32 = if (system == .gal) epoch_grid.galileo_toa_step_ms else epoch_grid.toa_step_ms;
    for (supplied) |entry| switch (entry) {
        .kepler => |a| if (a.sat.system == system) {
            const at = a.toa.inScale(scale);
            if (at.sub_ms == 0 and at.ms % step == 0) return a.toa;
        },
        .glonass => {},
    };
    return epoch_grid.gridTime(scale, start);
}

fn chooseDay(supplied: []const records.Almanac, start: GpsTime, leap: civil.Leap) gnav_system.Day {
    for (supplied) |entry| switch (entry) {
        .glonass => |a| return .{ .n4 = a.n4, .na = a.na },
        .kepler => {},
    };
    return gnav_system.dayOf(start, leap).?;
}

fn Completed(comptime T: type) type {
    return struct { records: []const T = &.{}, native: gnss_types.SatSet = .empty };
}

fn nativeFits(a: KeplerAlmanac) bool {
    return switch (a.sat.system) {
        .gps => field.fits(KeplerAlmanac, &lnav_fields.almanac_page, &a),
        .gal => galileo_almanac.misfit(a) == null,
        .bds => d1d2.almanacMisfit(a, bds_records.isGeo(a.sat.prn())) == null,
        .glo => unreachable,
    };
}

fn complete(arena: std.mem.Allocator, ephemerides: []const KeplerEphemeris, supplied: []const records.Almanac, system: gnss_types.System, epoch: GpsTime, native_needed: bool) std.mem.Allocator.Error!Completed(KeplerAlmanac) {
    var result: std.ArrayList(KeplerAlmanac) = .empty;
    for (supplied) |entry| switch (entry) {
        .kepler => |a| if (a.sat.system == system and a.toa.eql(epoch)) {
            var replaced = false;
            for (result.items) |*previous| if (previous.sat == a.sat) {
                previous.* = a;
                replaced = true;
                break;
            };
            if (!replaced) try result.append(arena, a);
        },
        .glonass => {},
    };
    var native: gnss_types.SatSet = .empty;
    if (native_needed) for (result.items) |record| native.insert(record.sat);
    var sats = system.satellites();
    while (sats.next()) |sat| {
        if (hasSat(result.items, sat)) continue;
        const record = nearest(ephemerides, sat, epoch, navigation_health.almanac_health_all) orelse continue;
        if (kepler.fromEphemeris(record, epoch)) |a| {
            var value = a;
            value.health = health(ephemerides, sat, epoch);
            try result.append(arena, value);
            if (native_needed and nativeFits(value)) native.insert(sat);
        }
    }
    return .{ .records = result.items, .native = native };
}

fn completeGlonass(arena: std.mem.Allocator, ephemerides: []const GlonassEphemeris, supplied: []const records.Almanac, day: gnav_system.Day, leap: civil.Leap, native_needed: bool) std.mem.Allocator.Error!Completed(GlonassAlmanac) {
    var result: std.ArrayList(GlonassAlmanac) = .empty;
    for (supplied) |entry| switch (entry) {
        .glonass => |a| if (a.n4 == day.n4 and a.na == day.na) {
            var replaced = false;
            for (result.items) |*previous| if (previous.sat == a.sat) {
                previous.* = a;
                replaced = true;
                break;
            };
            if (!replaced) try result.append(arena, a);
        },
        .kepler => {},
    };
    var native: gnss_types.SatSet = .empty;
    if (native_needed) for (result.items) |record| native.insert(record.sat);
    const target = GpsTime.fromGlonass(leap, .{ .n4 = day.n4, .nt = day.na, .ms_of_day = 0, .sub_ms = 0 });
    var sats = gnss_types.System.glo.satellites();
    while (sats.next()) |sat| {
        var known = false;
        for (result.items) |a| if (a.sat == sat) {
            known = true;
            break;
        };
        if (known) continue;
        const first = nearestGlonass(ephemerides, sat, target) orelse continue;
        var path = glonass.Path.init(first);
        const node = glonass.nodeEstimate(&path, target) orelse target;
        const best = nearestGlonass(ephemerides, sat, node) orelse first;
        if (glonass.fromEphemeris(best, day.n4, day.na, leap)) |value| {
            try result.append(arena, value);
            if (native_needed and field.fits(GlonassAlmanac, &gnav_fields.almanac_even, &value) and field.fits(GlonassAlmanac, &gnav_fields.almanac_odd, &value)) native.insert(sat);
        }
    }
    return .{ .records = result.items, .native = native };
}

fn nearest(ephemerides: []const KeplerEphemeris, sat: gnss_types.SatId, t: GpsTime, bits: u9) ?*const KeplerEphemeris {
    var best: ?*const KeplerEphemeris = null;
    var best_healthy = false;
    var best_dt: f64 = 0;
    for (ephemerides) |*e| {
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

fn health(ephemerides: []const KeplerEphemeris, sat: gnss_types.SatId, t: GpsTime) u9 {
    var word: u9 = 0;
    var open: u9 = navigation_health.almanac_health_all;
    while (nearest(ephemerides, sat, t, open)) |e| {
        const bits = e.extra.almanacHealthBits() & open;
        word |= e.extra.almanacHealth() & bits;
        open &= ~bits;
    }
    return word;
}

fn nearestGlonass(ephemerides: []const GlonassEphemeris, sat: gnss_types.SatId, t: GpsTime) ?*const GlonassEphemeris {
    var best: ?*const GlonassEphemeris = null;
    var best_dt: f64 = 0;
    for (ephemerides) |*g| {
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

fn hasSat(list: []const KeplerAlmanac, sat: gnss_types.SatId) bool {
    for (list) |a| if (a.sat == sat) return true;
    return false;
}
