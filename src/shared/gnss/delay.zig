const std = @import("std");
const Component = @import("../core.zig").types.Component;
const types = @import("../core.zig").types;
const spec = @import("spec.zig");
const records = @import("records.zig");
const gps = @import("gps/delay.zig");
const bds = @import("bds/delay.zig");
const galileo = @import("galileo/delay.zig");
const glonass = @import("glonass/delay.zig");
const bds_allocation = @import("bds/allocation.zig");

const carrier_component: Component = .data;

pub const Code = struct { signal: types.Signal, component: Component };

pub fn carrierCode(signal: types.Signal) Code {
    return .{ .signal = spec.get(signal).carrierSignal(), .component = carrier_component };
}

pub fn forGroupDelays(group_delay: *const records.GroupDelays, source: records.NavSource, prn: u8, signal: types.Signal, component: Component) ?f64 {
    if (source.system() != signal.system()) return null;
    return switch (signal.system()) {
        .gps => gps.forGroupDelays(group_delay, signal, component),
        .bds => bds.forGroupDelays(group_delay, prn, signal, component),
        .gal => galileo.forGroupDelays(group_delay, source, signal),
        .glo => null,
    };
}

pub fn forGlonass(group_delay: *const records.GroupDelays, signal: types.Signal) ?f64 {
    return glonass.forGroupDelays(group_delay, signal);
}

/// The delays a system sets by convention, not by its records: B3I and G1 are the BDS and GLONASS clock references,
/// E6 is taken at E1/E5a's, and the B2b of a satellite carrying PPP-B2b at B3I's.
pub fn convention(prn: u8, signal: types.Signal) bool {
    return switch (signal) {
        .b3i, .e6, .g1 => true,
        .b2b => bds_allocation.carriesPppB2b(prn),
        else => false,
    };
}

fn separates(signal: types.Signal) bool {
    return switch (signal.system()) {
        .gps => gps.separates(signal),
        .bds => bds.separates(signal),
        .gal, .glo => false,
    };
}

comptime {
    for (std.meta.tags(types.Signal)) |signal| {
        if (separates(signal) and spec.get(signal).stateBits(.pilot) == 0) @compileError("no pilot state bits for " ++ signal.name());
    }
}

pub const ClockRef = enum {
    p1p2,
    e1e5a,
    e1e5b,
    b1ib3i,
    g1g2,

    pub fn system(self: ClockRef) types.System {
        return switch (self) {
            .p1p2 => .gps,
            .e1e5a, .e1e5b => .gal,
            .b1ib3i => .bds,
            .g1g2 => .glo,
        };
    }

    pub const defaults: std.EnumArray(types.System, ClockRef) = .init(.{ .gps = .p1p2, .bds = .b1ib3i, .gal = .e1e5a, .glo = .g1g2 });

    pub const words: std.EnumArray(ClockRef, []const u8) = .init(.{ .p1p2 = "P1P2", .e1e5a = "E1E5a", .e1e5b = "E1E5b", .b1ib3i = "B1IB3I", .g1g2 = "G1G2" });

    pub fn name(self: ClockRef) []const u8 {
        return words.get(self);
    }

    pub fn pair(self: ClockRef) [2]types.Signal {
        return switch (self) {
            .p1p2 => .{ .l1ca, .l2c },
            .e1e5a => .{ .e1, .e5a },
            .e1e5b => .{ .e1, .e5b },
            .b1ib3i => .{ .b1i, .b3i },
            .g1g2 => .{ .g1, .g2 },
        };
    }

    pub fn frequencies(self: ClockRef) [2]f64 {
        const p = self.pair();
        const k: ?types.FreqId = if (self == .g1g2) .{ .k = 0 } else null;
        return .{ @floatFromInt(spec.get(p[0]).carrierHz(k)), @floatFromInt(spec.get(p[1]).carrierHz(k)) };
    }

    pub fn offset(self: ClockRef, a: f64, b: f64) f64 {
        if (self == .p1p2) return 0;
        const f = self.frequencies();
        return (f[0] * f[0] * a - f[1] * f[1] * b) / (f[0] * f[0] - f[1] * f[1]);
    }
};
