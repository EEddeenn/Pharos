const types = @import("../../core.zig").types;
const records = @import("../records.zig");
const Component = types.Component;

pub fn forGroupDelays(g: *const records.GroupDelays, signal: types.Signal, component: Component) ?f64 {
    return switch (signal) {
        .b1i => g.get(.tgd_b1i),
        .b2i => g.get(.tgd_b2i),
        .b3i => 0,
        .b1c => add(g.get(.tgd_b1cp), if (component == .data) g.get(.isc_b1cd) else null),
        .b2a => add(g.get(.tgd_b2ap), if (component == .data) g.get(.isc_b2ad) else null),
        .b2b => g.get(.tgd_b2bi),
        else => null,
    };
}

pub fn separates(signal: types.Signal) bool {
    return signal == .b1c or signal == .b2a;
}

fn add(a: ?f64, b: ?f64) ?f64 {
    return if (a) |x| x + (b orelse 0) else null;
}
