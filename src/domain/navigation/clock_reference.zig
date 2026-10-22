const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const signal_catalog = @import("domain/signals/catalog");

pub const ClockRef = enum {
    p1p2,
    e1e5a,
    e1e5b,
    b1ib3i,
    g1g2,

    pub const defaults: std.EnumArray(gnss_types.System, ClockRef) = .init(.{ .gps = .p1p2, .bds = .b1ib3i, .gal = .e1e5a, .glo = .g1g2 });

    pub const words: std.EnumArray(ClockRef, []const u8) = .init(.{ .p1p2 = "P1P2", .e1e5a = "E1E5a", .e1e5b = "E1E5b", .b1ib3i = "B1IB3I", .g1g2 = "G1G2" });

    pub fn system(self: ClockRef) gnss_types.System {
        return switch (self) {
            .p1p2 => .gps,
            .e1e5a, .e1e5b => .gal,
            .b1ib3i => .bds,
            .g1g2 => .glo,
        };
    }

    pub fn name(self: ClockRef) []const u8 {
        return words.get(self);
    }

    pub fn pair(self: ClockRef) [2]gnss_types.Signal {
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
        const k: ?gnss_types.FreqId = if (self == .g1g2) .{ .k = 0 } else null;
        return .{ @floatFromInt(signal_catalog.get(p[0]).carrierHz(k)), @floatFromInt(signal_catalog.get(p[1]).carrierHz(k)) };
    }

    pub fn offset(self: ClockRef, a: f64, b: f64) f64 {
        if (self == .p1p2) return 0;
        const f = self.frequencies();
        return (f[0] * f[0] * a - f[1] * f[1] * b) / (f[0] * f[0] - f[1] * f[1]);
    }
};

pub const ClockReferences = struct {
    galileo: enum(u8) { e1e5a, e1e5b } = .e1e5a,

    pub fn get(self: ClockReferences, system: gnss_types.System) ClockRef {
        return switch (system) {
            .gps => .p1p2,
            .bds => .b1ib3i,
            .gal => switch (self.galileo) {
                .e1e5a => .e1e5a,
                .e1e5b => .e1e5b,
            },
            .glo => .g1g2,
        };
    }
};
