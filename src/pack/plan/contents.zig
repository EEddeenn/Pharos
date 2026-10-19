const std = @import("std");
const shared = @import("shared");
const gnss = shared.gnss;
const bundle = shared.bundle;
const types = shared.core.types;
const NavSet = bundle.navigation.NavSet;
const NavFamily = types.NavFamily;
const Content = gnss.content.Content;
const Resolved = @import("resolve.zig").Resolved;

/// The families whose contents the legs carry: those the listed signals take, and those a running correction service
/// corrects a listed system against (HAS: Galileo against I/NAV, GPS against LNAV, which it corrects only with L1 C/A
/// listed; PPP-B2b: BDS against B-CNAV1, GPS against LNAV, Galileo against I/NAV; DC: GPS against LNAV; D2: BDS
/// against D1/D2, which its listed signals take).
pub fn needed(s: *const bundle.scenario.Scenario, set: *const NavSet, payload: *const gnss.payload.Payload) std.EnumSet(NavFamily) {
    var out = payload.families(s.signals);
    if (s.samples == null) return out;
    const systems = s.enabledSystems();
    if (s.has != null and s.signals.contains(.e6)) out.insert(.inav);
    if (s.ppp_b2b != null and s.signals.contains(.b2b)) {
        out.insert(.bcnav1);
        if (systems.contains(.gps)) out.insert(.lnav);
        if (systems.contains(.gal)) out.insert(.inav);
    }
    if (set.precise != null and (out.contains(.cnav) or out.contains(.cnav2))) {
        for (s.messages.gps) |p| if (p.content.differential != null) out.insert(.lnav);
    }
    return out;
}

/// A leg's contents: one per needed family its satellite carries, in the families' order, each from the family's
/// `prepare`. D1/D2's fit covers the leg's interval.
pub fn prepare(arena: std.mem.Allocator, set: *const NavSet, resolved: *const Resolved, families: std.EnumSet(NavFamily), interval: gnss.bds.d1d2.Interval) std.mem.Allocator.Error![]const Content {
    const out = try arena.alloc(Content, families.count());
    var it = families.iterator();
    var i: usize = 0;
    while (it.next()) |family| : (i += 1) out[i] = switch (resolved.reference) {
        .glonass => |g| .{ .gnav = gnss.glonass.gnav.prepare(&set.glonass[g], resolved.glonass_p1, resolved.group_delay.get(.delta_tau_n)) },
        .kepler => kepler(resolved.kepler(set).?, family, interval),
    };
    return out;
}

fn kepler(e: gnss.reference.Kepler, family: NavFamily, interval: gnss.bds.d1d2.Interval) Content {
    return switch (family) {
        .lnav => .{ .lnav = gnss.gps.lnav.prepare(e) },
        .cnav => .{ .cnav = gnss.gps.cnvx.prepare(e, .cnav) },
        .cnav2 => .{ .cnav2 = gnss.gps.cnvx.prepare(e, .cnav2) },
        .inav => .{ .inav = gnss.galileo.inav.prepare(e) },
        .fnav => .{ .fnav = gnss.galileo.fnav.prepare(e) },
        .d1d2 => .{ .d1d2 = gnss.bds.d1d2.prepare(.{ .record = e, .interval = interval }) },
        inline .bcnav1, .bcnav2, .bcnav3 => |f| @unionInit(Content, @tagName(f), gnss.bds.bcnav.prepare(e, @field(gnss.records.NavSource, @tagName(f)))),
        .cnav_has, .ppp_b2b, .gnav => unreachable,
    };
}

/// The needed families a satellite carries.
pub fn of(needed_families: std.EnumSet(NavFamily), payload: *const gnss.payload.Payload, sat: types.SatId) std.EnumSet(NavFamily) {
    var out: std.EnumSet(NavFamily) = .empty;
    var it = needed_families.iterator();
    while (it.next()) |family| {
        if (family != .cnav_has and family != .ppp_b2b and payload.carries(sat, family)) out.insert(family);
    }
    return out;
}
