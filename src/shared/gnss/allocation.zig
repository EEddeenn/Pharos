const types = @import("../core.zig").types;
const GpsTime = @import("../core.zig").time.GpsTime;
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
