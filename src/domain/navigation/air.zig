const std = @import("std");
const navigation_reference = @import("domain/navigation/reference");
const gnss_types = @import("domain/gnss_types");
const health_status = @import("domain/navigation/health");
const group_delay = @import("domain/navigation/group_delay");
const galileo_delay = @import("domain/navigation/delay/galileo");
const signal_catalog = @import("domain/signals/catalog");

const Carried = @import("domain/signals/payload").Carried;
const Content = @import("domain/messages/content").Content;

const Reference = navigation_reference.Reference;
const Kepler = navigation_reference.Kepler;

/// On the air, or the first reason a signal is not: the leg's record's health, then the signal's family, which cannot
/// carry the record, then the allocation, so that what the record says of a signal its satellite does not transmit
/// stays known.
pub const Status = enum { on_air, dead, not_carried, not_allocated };

pub const Origin = enum { broadcast, convention, assumed };

/// A signal's answer on a leg: one row per signal of the satellite's system, at its `spec.slot`. `declared` is the
/// Keplerian record whose declaration gives the health (an index of the navigation set's Keplerian records), kept for
/// display; null where none states it, and for GLONASS, whose health is its record's.
pub const Row = struct {
    status: Status,
    health: health_status.Status,
    delay_s: std.EnumArray(gnss_types.Component, f64),
    origin: Origin,
    declared: ?u32,
};

pub fn row(reference: Reference, carried: *const Carried, signal: gnss_types.Signal) Row {
    const family = carried.get(signal);
    switch (reference) {
        .kepler => |e| {
            const source = e.declaration(signal, family);
            const declared = if (source) |s| e.attribute(s).?.signalStatus(signal) else .unstated;
            const health: health_status.Status = switch (signal) {
                .b1c, .b2a, .b2b => if (wholeSatelliteUnhealthy(e)) .degraded else declared,
                else => declared,
            };
            const status: Status = if (!health.flies()) .dead else if (family == null) .not_allocated else .on_air;
            const record = if (source) |s| if (e.attributes) |attributes| if (attributes.get(s)) |entry| entry.record else null else null else null;
            // The B2b that carries PPP-B2b has no group delay of its own: it flies at B3I's, the BDS clock reference.
            if (family == .ppp_b2b) return .{ .status = status, .health = health, .delay_s = .initFill(0), .origin = .convention, .declared = record };
            const data = e.delay(signal, .data);
            const assumed = if (data == null and signal.system() == .gal) galileo_delay.withAssumed(e.group_delay, e.record.source(), signal) else 0;
            return .{
                .status = status,
                .health = health,
                .delay_s = .init(.{ .data = data orelse assumed, .pilot = e.delay(signal, .pilot) orelse assumed }),
                .origin = origin(signal, data),
                .declared = record,
            };
        },
        .glonass => |g| {
            const delay = group_delay.forGlonass(g.group_delay, signal);
            return .{
                .status = if (family == null) .not_allocated else .on_air,
                .health = health_status.flagged(!g.record.health),
                .delay_s = .initFill(delay orelse 0),
                .origin = origin(signal, delay),
                .declared = null,
            };
        },
    }
}

pub fn rows(arena: std.mem.Allocator, reference: Reference, sat: gnss_types.SatId, carried: *const Carried, contents: []const Content) std.mem.Allocator.Error![]const Row {
    const out = try arena.alloc(Row, signal_catalog.signalCount(sat.system));
    for (std.enums.values(gnss_types.Signal)) |signal| {
        if (signal.system() != sat.system) continue;
        var answer = row(reference, carried, signal);
        if (answer.status == .on_air and notCarried(carried.get(signal).?, contents)) answer.status = .not_carried;
        out[signal_catalog.slot(signal)] = answer;
    }
    return out;
}

/// A B-CNAV record's HS states the health of the whole satellite (BDS-OS-PS 3.0 5.3.3.2): it flags every B-CNAV signal.
fn wholeSatelliteUnhealthy(e: Kepler) bool {
    inline for (.{ .bcnav1, .bcnav2, .bcnav3 }) |source| {
        if (e.attribute(source)) |extra| if (@field(extra, @tagName(source)).signalsBad()) return true;
    }
    return false;
}

fn origin(signal: gnss_types.Signal, delay: ?f64) Origin {
    if (delay == null) return .assumed;
    return if (group_delay.convention(signal)) .convention else .broadcast;
}

/// Only CNAV and CNAV-2 send an unavailable ephemeris. The other navigation families leave a signal off the air when
/// they cannot carry its leg's reference.
fn notCarried(family: gnss_types.NavFamily, contents: []const Content) bool {
    switch (family) {
        .lnav, .inav, .fnav, .d1d2, .bcnav1, .bcnav2, .bcnav3, .gnav => {},
        else => return false,
    }
    for (contents) |*content| if (std.meta.activeTag(content.*) == family) return content.unfit() != null;
    return false;
}
