const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const types = core.types;
const attitude = core.attitude;
const spec = gnss.spec;
const ClockRef = gnss.delay.ClockRef;
const GpsTime = core.time.GpsTime;

pub const FreqCode = struct {
    system: types.System,
    band: u8,

    pub fn eql(a: FreqCode, b: FreqCode) bool {
        return a.system == b.system and a.band == b.band;
    }

    pub fn of(signal: types.Signal) FreqCode {
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
    sat: types.SatId,
    kind: []const u8,
    law: attitude.Law,
    valid_from: GpsTime,
    valid_until: ?GpsTime,
    offsets: []const Offset,

    pub fn offset(self: *const Antenna, code: FreqCode) ?[3]f64 {
        for (self.offsets) |o| if (o.code.eql(code)) return o.xyz_m;
        return null;
    }

    fn validAt(self: *const Antenna, t: GpsTime) bool {
        if (t.lessThan(self.valid_from)) return false;
        if (self.valid_until) |u| if (u.lessThan(t)) return false;
        return true;
    }
};

pub const Antex = struct {
    antennas: []const Antenna,

    pub fn find(self: Antex, sat: types.SatId, t: GpsTime) ?*const Antenna {
        var best: ?*const Antenna = null;
        for (self.antennas) |*a| {
            if (a.sat != sat or !a.validAt(t)) continue;
            if (best) |b| if (!b.valid_from.lessThan(a.valid_from)) continue;
            best = a;
        }
        return best;
    }

    pub fn validate(self: Antex) ?[]const u8 {
        for (self.antennas) |a| {
            if (!a.sat.valid()) return "an antenna names a satellite outside its system";
            for (a.offsets) |o| for (o.xyz_m) |v| if (!(@abs(v) <= max_offset_m)) return "an antenna offset is outside its range";
        }
        return null;
    }
};

pub const PhaseCentre = struct {
    reference_m: [3]f64,
    offset_m: [spec.max_per_system][3]f64,
    law: attitude.Law,
};

pub fn phaseCentre(atx: Antex, sat: types.SatId, t: GpsTime, ref: ClockRef) ?PhaseCentre {
    const ant = atx.find(sat, t) orelse return null;
    const pair = ref.pair();
    const a = ant.offset(.of(pair[0])) orelse return null;
    const b = ant.offset(.of(pair[1])) orelse return null;
    const f = ref.frequencies();
    const ga = f[0] * f[0];
    const gb = f[1] * f[1];
    var out: PhaseCentre = .{ .reference_m = undefined, .offset_m = @splat(@splat(0)), .law = ant.law };
    for (0..3) |i| out.reference_m[i] = (ga * a[i] - gb * b[i]) / (ga - gb);
    for (std.meta.tags(types.Signal)) |signal| {
        if (signal.system() != sat.system) continue;
        const own = ant.offset(.of(signal)) orelse continue;
        for (0..3) |i| out.offset_m[spec.slot(signal)][i] = own[i] - out.reference_m[i];
    }
    return out;
}
