const gnss_types = @import("domain/gnss_types");
const gps = @import("domain/signals/allocation/gps");
const bds = @import("domain/signals/allocation/bds");
const GpsTime = @import("domain/time/gps").GpsTime;

const Signal = gnss_types.Signal;
const SatId = gnss_types.SatId;

pub fn transmits(sat: SatId, signal: Signal, t: GpsTime) bool {
    if (sat.system != signal.system()) return false;
    const allocated = switch (sat.system) {
        .gps => gps.signalsAt(sat.prn(), t),
        .bds => bds.signalsAt(sat.prn(), t),
        .gal, .glo => return true,
    };
    return allocated.contains(signal);
}

pub fn start(system: gnss_types.System) ?GpsTime {
    return switch (system) {
        .gps => gps.start,
        .bds, .gal, .glo => null,
    };
}
