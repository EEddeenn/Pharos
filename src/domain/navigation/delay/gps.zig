const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");
const signals = @import("domain/signals/gps");

const Component = gnss_types.Component;

pub fn forGroupDelays(g: *const records.GroupDelays, signal: gnss_types.Signal, component: Component) ?f64 {
    const tgd = g.get(.tgd_l1ca) orelse return null;
    return switch (signal) {
        .l1ca => tgd - (g.get(.isc_l1ca) orelse 0),
        .l1c => tgd - (g.get(if (component == .data) .isc_l1cd else .isc_l1cp) orelse 0),
        .l2c => if (g.get(.isc_l2c)) |isc| tgd - isc else tgd * signals.l2c.ionoFactor(null),
        .l5 => if (g.get(if (component == .data) .isc_l5i5 else .isc_l5q5)) |isc| tgd - isc else tgd * signals.l5.ionoFactor(null),
        else => null,
    };
}

pub fn separates(signal: gnss_types.Signal) bool {
    return signal == .l1c or signal == .l5;
}
