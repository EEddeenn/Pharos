const std = @import("std");
const shared = @import("shared");
const gnss = shared.gnss;
const bundle = shared.bundle;
const types = shared.core.types;
const NavSet = bundle.navigation.NavSet;
const Resolved = @import("resolve.zig").Resolved;
const Row = gnss.air.Row;

pub fn air(set: *const NavSet, resolved: *const Resolved, carried: *const gnss.payload.Carried, signal: types.Signal) Row {
    const family = carried.get(signal);
    switch (resolved.reference) {
        .kepler => {
            const reference = resolved.kepler(set).?;
            const source = reference.declaration(signal, family);
            const declared = if (source) |s| reference.attribute(s).?.signalStatus(signal) else .unstated;
            const health: gnss.health.Status = switch (signal) {
                .b1c, .b2a, .b2b => if (wholeSatelliteUnhealthy(reference)) .degraded else declared,
                else => declared,
            };
            const status: gnss.air.Status = if (!health.flies()) .dead else if (family == null) .not_allocated else .on_air;
            const record = if (source) |s| resolved.attributes.from.get(s).? else null;
            // The B2b that carries PPP-B2b has no group delay of its own: it flies at B3I's, the BDS clock reference.
            if (family == .ppp_b2b) return .{ .status = status, .health = health, .delay_s = .initFill(0), .origin = .convention, .declared = record };
            const data = reference.delay(signal, .data);
            return .{
                .status = status,
                .health = health,
                .delay_s = .init(.{ .data = data orelse 0, .pilot = reference.delay(signal, .pilot) orelse 0 }),
                .origin = origin(signal, data),
                .declared = record,
            };
        },
        .glonass => |i| {
            const delay = gnss.delay.forGlonass(&resolved.group_delay, signal);
            return .{
                .status = if (family == null) .not_allocated else .on_air,
                .health = gnss.health.flagged(!set.glonass[i].health),
                .delay_s = .initFill(delay orelse 0),
                .origin = origin(signal, delay),
                .declared = null,
            };
        },
    }
}

/// A B-CNAV record's HS states the health of the whole satellite (BDS-OS-PS 3.0 5.3.3.2): it flags every B-CNAV signal.
fn wholeSatelliteUnhealthy(reference: gnss.reference.Kepler) bool {
    inline for (.{ .bcnav1, .bcnav2, .bcnav3 }) |source| {
        if (reference.attribute(source)) |extra| if (@field(extra, @tagName(source)).signalsBad()) return true;
    }
    return false;
}

fn origin(signal: types.Signal, delay: ?f64) gnss.air.Origin {
    if (delay == null) return .assumed;
    return if (gnss.delay.convention(signal)) .convention else .broadcast;
}

pub fn rows(arena: std.mem.Allocator, set: *const NavSet, sat: types.SatId, resolved: *const Resolved, carried: *const gnss.payload.Carried, contents: []const gnss.content.Content) std.mem.Allocator.Error![]const Row {
    const out = try arena.alloc(Row, gnss.spec.signalCount(sat.system));
    for (std.meta.tags(types.Signal)) |signal| {
        if (signal.system() != sat.system) continue;
        var row = air(set, resolved, carried, signal);
        if (row.status == .on_air and notCarried(carried.get(signal).?, contents)) row.status = .not_carried;
        out[gnss.spec.slot(signal)] = row;
    }
    return out;
}

/// B-CNAV and D1/D2 have no form that says their ephemeris is unavailable: a signal whose family cannot carry the leg's
/// reference is off the air.
fn notCarried(family: types.NavFamily, contents: []const gnss.content.Content) bool {
    switch (family) {
        .d1d2, .bcnav1, .bcnav2, .bcnav3 => {},
        else => return false,
    }
    for (contents) |*content| if (std.meta.activeTag(content.*) == family) return content.unfit() != null;
    return false;
}
