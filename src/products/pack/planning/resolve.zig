const std = @import("std");
const glonass_records = @import("domain/navigation/records/glonass");
const gnss_types = @import("domain/gnss_types");
const orbit_kepler = @import("domain/navigation/orbit/kepler");
const navigation_reference = @import("domain/navigation/reference");
const flight_plan = @import("simulation/model/flight_plan");
const records = @import("domain/navigation/records");
const select = @import("products/pack/planning/select");
const GpsTime = @import("domain/time/gps").GpsTime;
const Leap = @import("domain/time/civil").Leap;
const Ephemerides = records.Ephemerides;
const Ref = flight_plan.Ref;

/// What the packer resolves for a satellite at a time: the reference, its group delays and P1 word, and the families'
/// attributes the rows and the contents are computed from.
pub const Resolved = struct {
    reference: Ref,
    group_delay: records.GroupDelays = .{},
    attributes: navigation_reference.Attributes = .{},
    glonass_p1: u2 = 0,

    pub fn input(self: *const Resolved, set: *const Ephemerides) navigation_reference.Reference {
        return switch (self.reference) {
            .kepler => .{ .kepler = self.kepler(set).? },
            .glonass => |k| .{ .glonass = .{ .record = &set.glonass[k], .group_delay = &self.group_delay } },
        };
    }

    pub fn kepler(self: *const Resolved, set: *const Ephemerides) ?navigation_reference.Kepler {
        return switch (self.reference) {
            .kepler => |k| .{ .record = &set.kepler[k], .group_delay = &self.group_delay, .attributes = &self.attributes },
            .glonass => null,
        };
    }
};

pub fn binding(set: *const Ephemerides, chosen: select.Chosen, t: GpsTime, leap: Leap) Resolved {
    var out: Resolved = .{ .reference = chosen.reference };
    const index = switch (chosen.reference) {
        .kepler => |index| index,
        .glonass => |index| {
            const g = &set.glonass[index];
            out.glonass_p1 = select.glonassStep(set, g, leap);
            if (g.delta_tau_n orelse glonassDonor(set, g, t, leap)) |d| out.group_delay.put(.delta_tau_n, d);
            return out;
        },
    };
    const e = &set.kepler[index];
    out.group_delay = e.group_delay;
    const end: GpsTime = .{ .ms = flight_plan.nextLegBoundary(e.sat.system, t, leap).ms };
    for (std.enums.values(records.GroupDelayTerm)) |term| {
        if (out.group_delay.contains(term)) continue;
        var best: ?*const records.KeplerEphemeris = null;
        for (set.kepler) |*donor| {
            if (!eligible(donor, e.sat, t, end) or !donor.group_delay.contains(term)) continue;
            if (best) |previous| if (!nearer(donor, previous, e.toe)) continue;
            best = donor;
        }
        if (best) |donor| out.group_delay.put(term, donor.group_delay.get(term).?);
    }
    out.attributes = chosen.attributes orelse attributesAt(set, index, t, leap);
    return out;
}

pub fn attributesAt(set: *const Ephemerides, index: u32, t: GpsTime, leap: Leap) navigation_reference.Attributes {
    const e = &set.kepler[index];
    var out: navigation_reference.Attributes = .{};
    const end: GpsTime = .{ .ms = flight_plan.nextLegBoundary(e.sat.system, t, leap).ms };
    for (std.enums.values(records.NavSource)) |source| {
        if (source.system() != e.sat.system) continue;
        if (source == e.source()) {
            out.put(e.extra, index);
            continue;
        }
        var latest: ?u32 = null;
        for (set.kepler, 0..) |*donor, i| {
            if (donor.source() != source or !eligible(donor, e.sat, t, end)) continue;
            if (latest) |l| {
                const previous = &set.kepler[l];
                if (adopted(donor).lessThan(adopted(previous))) continue;
                if (adopted(donor).eql(adopted(previous)) and !select.recordBefore(donor, previous)) continue;
            }
            latest = @intCast(i);
        }
        if (latest) |l| out.put(navigation_reference.attributesOf(e, &set.kepler[l]), l);
    }
    return out;
}

fn glonassDonor(set: *const Ephemerides, g: *const records.GlonassEphemeris, t: GpsTime, leap: Leap) ?f64 {
    const end: GpsTime = .{ .ms = flight_plan.nextLegBoundary(.glo, t, leap).ms };
    var best: ?*const records.GlonassEphemeris = null;
    for (set.glonass) |*donor| {
        if (donor.sat != g.sat or donor.delta_tau_n == null or @abs(t.secondsSince(donor.tb)) > orbit_kepler.window_s) continue;
        if (!glonass_records.adoption(donor.tb, leap).lessThan(end)) continue;
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

fn eligible(e: *const records.KeplerEphemeris, sat: gnss_types.SatId, t: GpsTime, end: GpsTime) bool {
    return e.sat == sat and @abs(t.secondsSince(e.toe)) <= orbit_kepler.window_s and adopted(e).lessThan(end);
}

fn nearer(a: *const records.KeplerEphemeris, b: *const records.KeplerEphemeris, reference: GpsTime) bool {
    const da = @abs(a.toe.secondsSince(reference));
    const db = @abs(b.toe.secondsSince(reference));
    if (da != db) return da < db;
    if (!adopted(a).eql(adopted(b))) return adopted(b).lessThan(adopted(a));
    return select.recordBefore(a, b);
}
