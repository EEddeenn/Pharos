const gnss_types = @import("domain/gnss_types");

const GpsTime = @import("domain/time/gps").GpsTime;

pub const FreqCode = struct {
    system: gnss_types.System,
    band: u8,

    pub fn eql(a: FreqCode, b: FreqCode) bool {
        return a.system == b.system and a.band == b.band;
    }

    pub fn of(signal: gnss_types.Signal) FreqCode {
        return switch (signal) {
            .l1ca, .l1c => .{ .system = .gps, .band = 1 },
            .l2c => .{ .system = .gps, .band = 2 },
            .l5 => .{ .system = .gps, .band = 5 },
            .b1c => .{ .system = .bds, .band = 1 },
            .b1i => .{ .system = .bds, .band = 2 },
            .b2a => .{ .system = .bds, .band = 5 },
            .b3i => .{ .system = .bds, .band = 6 },
            .b2i, .b2b => .{ .system = .bds, .band = 7 },
            .e1 => .{ .system = .gal, .band = 1 },
            .e5a => .{ .system = .gal, .band = 5 },
            .e6 => .{ .system = .gal, .band = 6 },
            .e5b => .{ .system = .gal, .band = 7 },
            .g1 => .{ .system = .glo, .band = 1 },
            .g2 => .{ .system = .glo, .band = 2 },
        };
    }
};

pub const Offset = struct {
    code: FreqCode,
    xyz_m: [3]f64,
};

pub const max_offset_m: f64 = 1000;

pub const Antenna = struct {
    sat: gnss_types.SatId,
    kind: []const u8,
    valid_from: GpsTime,
    valid_until: ?GpsTime,
    offsets: []const Offset,

    pub fn offset(self: *const Antenna, code: FreqCode) ?[3]f64 {
        for (self.offsets) |o| if (o.code.eql(code)) return o.xyz_m;
        return null;
    }
};
