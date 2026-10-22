const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const signal_catalog = @import("domain/signals/catalog");
const records = @import("domain/navigation/records");
const gps = @import("domain/navigation/delay/gps");
const bds = @import("domain/navigation/delay/bds");
const galileo = @import("domain/navigation/delay/galileo");
const glonass = @import("domain/navigation/delay/glonass");

const Component = gnss_types.Component;

const carrier_component: Component = .data;

pub const Code = struct { signal: gnss_types.Signal, component: Component };

pub fn carrierCode(signal: gnss_types.Signal) Code {
    return .{ .signal = signal_catalog.get(signal).carrierSignal(), .component = carrier_component };
}

pub fn forGroupDelays(group_delay: *const records.GroupDelays, source: records.NavSource, signal: gnss_types.Signal, component: Component) ?f64 {
    if (source.system() != signal.system()) return null;
    return switch (signal.system()) {
        .gps => gps.forGroupDelays(group_delay, signal, component),
        .bds => bds.forGroupDelays(group_delay, signal, component),
        .gal => galileo.forGroupDelays(group_delay, source, signal),
        .glo => null,
    };
}

pub fn forGlonass(group_delay: *const records.GroupDelays, signal: gnss_types.Signal) ?f64 {
    return glonass.forGroupDelays(group_delay, signal);
}

/// The delays a system sets by convention, not by its records: B3I and G1 are the BDS and GLONASS clock references,
/// and E6 is taken at E1/E5a's.
pub fn convention(signal: gnss_types.Signal) bool {
    return switch (signal) {
        .b3i, .e6, .g1 => true,
        else => false,
    };
}

fn separates(signal: gnss_types.Signal) bool {
    return switch (signal.system()) {
        .gps => gps.separates(signal),
        .bds => bds.separates(signal),
        .gal, .glo => false,
    };
}

comptime {
    for (std.enums.values(gnss_types.Signal)) |signal| {
        if (separates(signal) and signal_catalog.get(signal).stateBits(.pilot) == 0) @compileError("no pilot state bits for " ++ signal.name());
    }
}
