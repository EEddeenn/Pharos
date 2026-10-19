const types = @import("../../core.zig").types;
const records = @import("../records.zig");

pub fn forGroupDelays(g: *const records.GroupDelays, signal: types.Signal) ?f64 {
    return switch (signal) {
        .g1 => 0,
        .g2 => g.get(.delta_tau_n),
        else => null,
    };
}
