const types = @import("../../core.zig").types;
const records = @import("records.zig");

pub fn forSignal(g: *const records.GlonassEphemeris, signal: types.Signal) ?f64 {
    return switch (signal) {
        .g1 => 0,
        .g2 => g.delta_tau_n,
        else => null,
    };
}
