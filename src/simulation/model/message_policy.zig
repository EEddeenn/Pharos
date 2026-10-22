const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const NavFamily = gnss_types.NavFamily;
const ServicePlan = @import("simulation/model/services").ServicePlan;
const Payload = @import("domain/signals/payload").Payload;

/// The families whose contents the legs carry: those the listed signals take, and those a running correction service
/// corrects a listed system against (HAS: Galileo against I/NAV, GPS against LNAV, which it corrects only with L1 C/A
/// listed; PPP-B2b: BDS against B-CNAV1, GPS against LNAV, Galileo against I/NAV; DC: GPS against LNAV; D2: BDS
/// against D1/D2, which its listed signals take).
pub fn needed(signals: std.EnumSet(gnss_types.Signal), services: ServicePlan, payload: *const Payload) std.EnumSet(NavFamily) {
    var out = payload.families(signals);
    var systems: std.EnumSet(gnss_types.System) = .empty;
    var selected = signals.iterator();
    while (selected.next()) |signal| systems.insert(signal.system());
    if (services.runs(.has)) out.insert(.inav);
    if (services.runs(.ppp_b2b)) {
        out.insert(.bcnav1);
        if (systems.contains(.gps)) out.insert(.lnav);
        if (systems.contains(.gal)) out.insert(.inav);
    }
    if (services.runs(.gps_differential)) out.insert(.lnav);
    return out;
}

/// The needed families a satellite carries.
pub fn of(needed_families: std.EnumSet(NavFamily), payload: *const Payload, sat: gnss_types.SatId) std.EnumSet(NavFamily) {
    var out: std.EnumSet(NavFamily) = .empty;
    var it = needed_families.iterator();
    while (it.next()) |family| {
        if (family != .cnav_has and family != .ppp_b2b and payload.carries(sat, family)) out.insert(family);
    }
    return out;
}
