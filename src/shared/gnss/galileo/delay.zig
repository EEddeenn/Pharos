const types = @import("../../core.zig").types;
const records = @import("../records.zig");
const signals = @import("signals.zig");

const Term = records.GroupDelayTerm;

pub fn forGroupDelays(g: *const records.GroupDelays, source: records.NavSource, signal: types.Signal) ?f64 {
    const clock: Term = if (source == .fnav) .bgd_e1e5a else .bgd_e1e5b;
    return switch (signal) {
        .e1 => g.get(clock),
        .e5a => second(g, clock, .bgd_e1e5a, signals.e5a.ionoFactor(null)),
        .e5b => second(g, clock, .bgd_e1e5b, signals.e5b.ionoFactor(null)),
        .e6 => 0,
        else => null,
    };
}

fn second(g: *const records.GroupDelays, clock: Term, own: Term, gamma: f64) ?f64 {
    const bgd = g.get(own) orelse return null;
    if (own == clock) return gamma * bgd;
    const e1 = g.get(clock) orelse return null;
    return e1 + (gamma - 1) * bgd;
}
