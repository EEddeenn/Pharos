const std = @import("std");
const types = @import("../core.zig").types;
const GpsTime = @import("../core.zig").time.GpsTime;
const spec = @import("spec.zig");
const gps = @import("gps/allocation.zig");
const bds = @import("bds/allocation.zig");

const Signal = types.Signal;
const SatId = types.SatId;

pub fn transmits(sat: SatId, signal: Signal, t: GpsTime) bool {
    if (sat.system != signal.system()) return false;
    const allocated = switch (sat.system) {
        .gps => gps.signalsAt(sat.prn(), t),
        .bds => bds.signalsAt(sat.prn(), t),
        .gal, .glo => return true,
    };
    return allocated.contains(signal);
}

pub fn start(system: types.System) ?GpsTime {
    return switch (system) {
        .gps => gps.start,
        .bds, .gal, .glo => null,
    };
}

pub fn transmitsFamily(sat: SatId, family: types.NavFamily, t: GpsTime) bool {
    for (std.enums.values(Signal)) |signal| if (spec.get(signal).family == family and transmits(sat, signal, t)) return true;
    return false;
}

pub const Allocation = struct {
    signals: [256]std.EnumSet(Signal),

    pub fn transmits(self: *const Allocation, sat: SatId, signal: Signal) bool {
        return self.signals[sat.key()].contains(signal);
    }

    pub fn transmitsAny(self: *const Allocation, sat: SatId, signals: std.EnumSet(Signal)) bool {
        return self.signals[sat.key()].intersectWith(signals).count() != 0;
    }

    pub fn transmitsFamily(self: *const Allocation, sat: SatId, family: types.NavFamily) bool {
        for (std.enums.values(Signal)) |signal| if (spec.get(signal).family == family and self.transmits(sat, signal)) return true;
        return false;
    }
};

pub fn at(t: GpsTime) Allocation {
    var out: Allocation = .{ .signals = @splat(.empty) };
    for (&out.signals, 0..) |*set, i| {
        const sat: SatId = .fromKey(@intCast(i));
        for (std.enums.values(Signal)) |signal| if (transmits(sat, signal, t)) set.insert(signal);
    }
    return out;
}
