const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const signal_catalog = @import("domain/signals/catalog");
const allocation = @import("domain/signals/allocation");
const bds_records = @import("domain/navigation/records/bds");
const GpsTime = @import("domain/time/gps").GpsTime;

const Signal = gnss_types.Signal;
const SatId = gnss_types.SatId;
const NavFamily = gnss_types.NavFamily;

/// One satellite's payload: the family that carries each signal it transmits, null for the others.
pub const Carried = std.EnumArray(Signal, ?NavFamily);

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

/// The family that carries a signal on a satellite transmitting it: the signal's own, but PPP-B2b on the B2b of a BDS
/// GEO satellite.
pub fn familyFor(sat: SatId, signal: Signal) NavFamily {
    if (signal == .b2b and bds_records.isGeo(sat.prn())) return .ppp_b2b;
    return signal_catalog.get(signal).family;
}

pub fn familyAt(sat: SatId, signal: Signal, t: GpsTime) ?NavFamily {
    if (!allocation.transmits(sat, signal, t)) return null;
    return familyFor(sat, signal);
}

pub fn at(t: GpsTime) Payload {
    var out: Payload = .{ .satellites = @splat(.initFill(null)) };
    for (gnss_types.System.all) |system| {
        var sats = system.satellites();
        while (sats.next()) |sat| {
            for (std.enums.values(Signal)) |signal| out.satellites[sat.key()].set(signal, familyAt(sat, signal, t));
        }
    }
    return out;
}
