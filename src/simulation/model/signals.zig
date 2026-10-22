const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const signal_payload = @import("domain/signals/payload");
const allocation = @import("domain/signals/allocation");
const GpsTime = @import("domain/time/gps").GpsTime;

pub fn systems(signals: std.EnumSet(gnss_types.Signal)) std.EnumSet(gnss_types.System) {
    var result = std.EnumSet(gnss_types.System).empty;
    var it = signals.iterator();
    while (it.next()) |signal| result.insert(signal.system());
    return result;
}

pub fn carries(signals: std.EnumSet(gnss_types.Signal), start: GpsTime, family: gnss_types.NavFamily) bool {
    var it = signals.iterator();
    while (it.next()) |signal| {
        var satellites = signal.system().satellites();
        while (satellites.next()) |sat| if (signal_payload.familyAt(sat, signal, start) == family) return true;
    }
    return false;
}

pub fn listedSignal(signals: std.EnumSet(gnss_types.Signal), start: GpsTime, sat: gnss_types.SatId) ?gnss_types.Signal {
    var it = signals.iterator();
    while (it.next()) |signal| if (allocation.transmits(sat, signal, start)) return signal;
    return null;
}

pub fn transmits(signals: std.EnumSet(gnss_types.Signal), mask_out: std.EnumArray(gnss_types.System, gnss_types.SatSet), start: GpsTime, sat: gnss_types.SatId) bool {
    return !mask_out.get(sat.system).contains(sat) and listedSignal(signals, start, sat) != null;
}
