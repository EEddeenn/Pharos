const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");

pub fn forGroupDelays(g: *const records.GroupDelays, signal: gnss_types.Signal) ?f64 {
    return switch (signal) {
        .g1 => 0,
        .g2 => g.get(.delta_tau_n),
        else => null,
    };
}
