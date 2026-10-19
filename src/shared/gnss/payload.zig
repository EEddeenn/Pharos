const std = @import("std");
const types = @import("../core.zig").types;
const GpsTime = @import("../core.zig").time.GpsTime;
const spec = @import("spec.zig");
const allocation = @import("allocation.zig");
const bds_records = @import("bds/records.zig");

const Signal = types.Signal;
const SatId = types.SatId;
const NavFamily = types.NavFamily;

/// One satellite's payload: the family that carries each signal it transmits, null for the others.
pub const Carried = std.EnumArray(Signal, ?NavFamily);

pub fn familyAt(sat: SatId, signal: Signal, t: GpsTime) ?NavFamily {
    if (!allocation.transmits(sat, signal, t)) return null;
    return spec.get(signal).family;
}

/// PPP-B2b is the B2b message of the BDS GEO satellites: a GEO satellite carries it where it transmits B2b.
pub fn pppB2b(sat: SatId, carried: *const Carried) bool {
    return carried.get(.b2b) != null and bds_records.isGeo(sat.prn());
}

/// What each satellite transmits, frozen at the run start as the allocation is: the one answer to which family carries
/// a signal on a satellite.
pub const Payload = struct {
    satellites: [256]Carried,

    pub fn of(self: *const Payload, sat: SatId) *const Carried {
        return &self.satellites[sat.key()];
    }

    pub fn familyOf(self: *const Payload, sat: SatId, signal: Signal) ?NavFamily {
        return self.satellites[sat.key()].get(signal);
    }

    pub fn transmits(self: *const Payload, sat: SatId, signal: Signal) bool {
        return self.familyOf(sat, signal) != null;
    }

    pub fn transmitted(self: *const Payload, sat: SatId) std.EnumSet(Signal) {
        var out: std.EnumSet(Signal) = .empty;
        for (std.enums.values(Signal)) |signal| if (self.transmits(sat, signal)) out.insert(signal);
        return out;
    }

    pub fn transmitsAny(self: *const Payload, sat: SatId, signals: std.EnumSet(Signal)) bool {
        return self.transmitted(sat).intersectWith(signals).count() != 0;
    }

    pub fn carries(self: *const Payload, sat: SatId, family: NavFamily) bool {
        for (self.satellites[sat.key()].values) |carried| if (carried == family) return true;
        return false;
    }

    /// The families the signals take on any satellite: the message sets they need.
    pub fn families(self: *const Payload, signals: std.EnumSet(Signal)) std.EnumSet(NavFamily) {
        var out: std.EnumSet(NavFamily) = .empty;
        for (&self.satellites) |*carried| {
            var it = signals.iterator();
            while (it.next()) |signal| if (carried.get(signal)) |family| out.insert(family);
        }
        return out;
    }
};

pub fn at(t: GpsTime) Payload {
    var out: Payload = .{ .satellites = @splat(.initFill(null)) };
    for (types.System.all) |system| {
        var sats = system.satellites();
        while (sats.next()) |sat| {
            for (std.enums.values(Signal)) |signal| out.satellites[sat.key()].set(signal, familyAt(sat, signal, t));
        }
    }
    return out;
}
