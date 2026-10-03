const types = @import("../../core.zig").types;
const health = @import("../health.zig");

pub const sisa_napa: u8 = 255;
const sisa_max_m = 6;

pub fn sisaIndex(meters: f64) u8 {
    if (!(meters >= 0 and meters <= sisa_max_m)) return sisa_napa;
    const centimetres = @round(meters * 100.0);
    const cm: i64 = @intFromFloat(centimetres);
    if (cm < 50) return @intCast(cm);
    if (cm < 100) return @intCast(@divTrunc(cm - 50, 2) + 50);
    if (cm < 200) return @intCast(@divTrunc(cm - 100, 4) + 75);
    return @intCast(@divTrunc(cm - 200, 16) + 100);
}

pub const E5aDeclaration = struct {
    hs: u2,
    dvs: bool,
    sisa_index: u8,

    fn status(self: E5aDeclaration) health.Status {
        return statusOf(self.hs, self.dvs);
    }
};

fn signalUsable(hs: u2, dvs: bool) bool {
    return hs == 0 and !dvs;
}

fn statusOf(hs: u2, dvs: bool) health.Status {
    if (hs == 1) return .dead;
    return if (hs != 0 or dvs) .degraded else .ok;
}

pub const InavExtra = struct {
    pub const transmission_lead_s: ?f64 = null;
    sisa_index: u8,
    iod_nav: u10,
    e1b_hs: u2,
    e5b_hs: u2,
    e1b_dvs: bool,
    e5b_dvs: bool,
    e5a: ?E5aDeclaration = null,

    pub const almanac_health_bits: u9 = 0b001111;

    pub fn e1Usable(self: InavExtra) bool {
        return signalUsable(self.e1b_hs, self.e1b_dvs);
    }
    pub fn e5bUsable(self: InavExtra) bool {
        return signalUsable(self.e5b_hs, self.e5b_dvs);
    }

    pub fn healthy(self: InavExtra) bool {
        return self.signalStatus(.e1).flies() or self.signalStatus(.e5b).flies();
    }

    pub fn signalStatus(self: InavExtra, signal: types.Signal) health.Status {
        return switch (signal) {
            .e1 => statusOf(self.e1b_hs, self.e1b_dvs),
            .e5b => statusOf(self.e5b_hs, self.e5b_dvs),
            .e5a => if (self.e5a) |d| d.status() else .ok,
            else => .unstated,
        };
    }

    pub fn almanacHealth(self: InavExtra) u9 {
        return (@as(u9, self.e5b_hs) << 2) | self.e1b_hs;
    }
};

pub const FnavExtra = struct {
    pub const transmission_lead_s: ?f64 = null;
    sisa_index: u8,
    iod_nav: u10,
    e5a_hs: u2,
    e5a_dvs: bool,

    pub const almanac_health_bits: u9 = 0b110000;

    pub fn healthy(self: FnavExtra) bool {
        return self.signalStatus(.e5a).flies();
    }

    pub fn signalStatus(self: FnavExtra, signal: types.Signal) health.Status {
        return if (signal == .e5a) statusOf(self.e5a_hs, self.e5a_dvs) else .unstated;
    }

    pub fn almanacHealth(self: FnavExtra) u9 {
        return @as(u9, self.e5a_hs) << 4;
    }

    pub fn declaration(self: FnavExtra) E5aDeclaration {
        return .{ .hs = self.e5a_hs, .dvs = self.e5a_dvs, .sisa_index = self.sisa_index };
    }
};
