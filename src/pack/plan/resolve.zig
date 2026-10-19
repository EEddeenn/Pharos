const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const bundle = shared.bundle;
const records = gnss.records;
const select = @import("select.zig");
const GpsTime = core.time.GpsTime;
const Leap = core.civil.Leap;
const NavSet = bundle.navigation.NavSet;
const Ref = bundle.plan.Ref;

pub fn binding(set: *const NavSet, reference: Ref, t: GpsTime, leap: Leap) bundle.plan.Binding {
    var out: bundle.plan.Binding = .{ .reference = reference, .air = &.{} };
    const e = switch (reference) {
        .kepler => |index| &set.kepler[index],
        .glonass => |index| {
            const g = &set.glonass[index];
            out.glonass_p1 = select.glonassStep(set, g, leap);
            if (g.delta_tau_n orelse glonassDonor(set, g, t, leap)) |d| out.group_delay.put(.delta_tau_n, d);
            return out;
        },
    };
    out.group_delay = e.group_delay;
    const end: GpsTime = .{ .ms = bundle.plan.nextLegBoundary(e.sat.system, t, leap).ms };
    for (std.meta.tags(records.GroupDelayTerm)) |term| {
        if (out.group_delay.contains(term)) continue;
        var best: ?*const records.KeplerEphemeris = null;
        for (set.kepler) |*donor| {
            if (!eligible(donor, e.sat, t, end) or !donor.group_delay.contains(term)) continue;
            if (best) |previous| if (!nearer(donor, previous, e.toe)) continue;
            best = donor;
        }
        if (best) |donor| out.group_delay.put(term, donor.group_delay.get(term).?);
    }
    out.attributes = attributesAt(set, e, t, leap);
    return out;
}

pub fn attributesAt(set: *const NavSet, e: *const records.KeplerEphemeris, t: GpsTime, leap: Leap) gnss.reference.Attributes {
    var out: gnss.reference.Attributes = .{};
    const end: GpsTime = .{ .ms = bundle.plan.nextLegBoundary(e.sat.system, t, leap).ms };
    for (std.meta.tags(records.NavSource)) |source| {
        if (source.system() != e.sat.system) continue;
        if (source == e.source()) {
            out.put(e.extra);
            continue;
        }
        var latest: ?*const records.KeplerEphemeris = null;
        for (set.kepler) |*donor| {
            if (donor.source() != source or !eligible(donor, e.sat, t, end)) continue;
            if (latest) |previous| {
                if (adopted(donor).lessThan(adopted(previous))) continue;
                if (adopted(donor).eql(adopted(previous)) and !select.recordBefore(donor, previous)) continue;
            }
            latest = donor;
        }
        if (latest) |donor| out.put(attributes(e, donor));
    }
    return out;
}

fn glonassDonor(set: *const NavSet, g: *const records.GlonassEphemeris, t: GpsTime, leap: Leap) ?f64 {
    const end: GpsTime = .{ .ms = bundle.plan.nextLegBoundary(.glo, t, leap).ms };
    var best: ?*const records.GlonassEphemeris = null;
    for (set.glonass) |*donor| {
        if (donor.sat != g.sat or donor.delta_tau_n == null or @abs(t.secondsSince(donor.tb)) > gnss.kepler.window_s) continue;
        if (!gnss.glonass.records.adoption(donor, leap).lessThan(end)) continue;
        if (best) |previous| {
            const d = @abs(donor.tb.secondsSince(g.tb));
            const p = @abs(previous.tb.secondsSince(g.tb));
            if (d > p or (d == p and !previous.tb.lessThan(donor.tb))) continue;
        }
        best = donor;
    }
    return if (best) |donor| donor.delta_tau_n else null;
}

fn adopted(e: *const records.KeplerEphemeris) GpsTime {
    if (e.transmitted) |t| return t;
    if (e.extra.transmissionLead()) |lead| return e.toe.addSeconds(-lead);
    return e.toe;
}

fn eligible(e: *const records.KeplerEphemeris, sat: core.types.SatId, t: GpsTime, end: GpsTime) bool {
    return e.sat == sat and @abs(t.secondsSince(e.toe)) <= gnss.kepler.window_s and adopted(e).lessThan(end);
}

fn nearer(a: *const records.KeplerEphemeris, b: *const records.KeplerEphemeris, reference: GpsTime) bool {
    const da = @abs(a.toe.secondsSince(reference));
    const db = @abs(b.toe.secondsSince(reference));
    if (da != db) return da < db;
    if (!adopted(a).eql(adopted(b))) return adopted(b).lessThan(adopted(a));
    return select.recordBefore(a, b);
}

fn gpsUra(e: *const records.KeplerEphemeris) gnss.gps.accuracy.Ura {
    return switch (e.extra) {
        .lnav => |x| gnss.gps.accuracy.ofLnav(x.ura_index),
        .cnav => |x| x.ura,
        .cnav2 => |x| x.ura,
        else => .{ .ed = 15, .ned0 = 15, .ned1 = 7, .ned2 = 7 },
    };
}

fn galileoIssue(e: *const records.KeplerEphemeris) u10 {
    return switch (e.extra) {
        .inav => |x| x.iod_nav,
        .fnav => |x| x.iod_nav,
        else => @truncate(e.iode),
    };
}

fn attributes(e: *const records.KeplerEphemeris, donor: *const records.KeplerEphemeris) records.SourceExtra {
    const same = std.meta.eql(e.parameters(), donor.parameters());
    var out = donor.extra;
    switch (out) {
        .lnav => |*x| {
            x.ura_index = switch (e.extra) {
                .lnav => |own| own.ura_index,
                else => if (same) x.ura_index else 15,
            };
        },
        .cnav => |*x| x.ura = gpsUra(e),
        .cnav2 => |*x| x.ura = gpsUra(e),
        inline .inav, .fnav => |*x| {
            const issue = galileoIssue(e);
            if (!e.toe.eql(donor.toe) or x.iod_nav != issue) x.sisa_index = gnss.galileo.records.sisa_napa;
            x.iod_nav = issue;
        },
        .d1d2 => |*x| {
            x.ura_index = switch (e.extra) {
                .d1d2 => |own| own.ura_index,
                else => if (same) x.ura_index else 15,
            };
            if (e.source() != .d1d2) {
                x.aodc = 31;
                x.aode = 31;
            }
        },
        .bcnav1, .bcnav2, .bcnav3 => |*x| {
            x.sat_type = switch (e.extra) {
                .bcnav1, .bcnav2, .bcnav3 => |own| own.sat_type,
                else => gnss.bds.records.satTypeOf(e.sat.prn(), e.sqrt_a),
            };
            switch (e.extra) {
                .bcnav1, .bcnav2, .bcnav3 => |own| {
                    x.sismai = own.sismai;
                    x.sisai_oe = own.sisai_oe;
                    x.sisai_ocb = own.sisai_ocb;
                    x.sisai_oc1 = own.sisai_oc1;
                    x.sisai_oc2 = own.sisai_oc2;
                },
                else => if (!same) {
                    x.sismai = 15;
                    x.sisai_oe = 31;
                    x.sisai_ocb = 31;
                    x.sisai_oc1 = 7;
                    x.sisai_oc2 = 7;
                    if (x.b1c) |*flags| flags.aif = true;
                    if (x.b2a) |*flags| flags.aif = true;
                    if (x.b2b) |*flags| flags.aif = true;
                },
            }
        },
    }
    return out;
}
