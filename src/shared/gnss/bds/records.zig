const types = @import("../../core.zig").types;
const time = @import("../../core.zig").time;
const auxiliary = @import("../auxiliary.zig");
const health = @import("../health.zig");
const almanac_reference = @import("../almanac_reference.zig");

const BdtLeap = struct { delta_tls: i16, delta_tlsf: i16, wn_lsf: u16, dn: i16 };

pub fn bdtLeap(leap: auxiliary.LeapSecondSchedule) ?BdtLeap {
    const current: i16 = leap.delta_tls;
    const future: i16 = leap.delta_tlsf;
    const day: i16 = leap.dn;
    const epoch_week: u16 = time.bds_week_offset;
    if (leap.wn_lsf < epoch_week) return null;
    return .{
        .delta_tls = current - 14,
        .delta_tlsf = future - 14,
        .wn_lsf = leap.wn_lsf - epoch_week,
        .dn = day - 1,
    };
}

pub fn isGeo(prn: u8) bool {
    return prn <= 5 or prn >= 59;
}

pub const SatType = enum(u2) { geo = 1, igso = 2, meo = 3 };

const igso_min_axis_m = 4.0e7;

pub fn satTypeOf(prn: u8, sqrt_a: f64) SatType {
    if (isGeo(prn)) return .geo;
    return if (sqrt_a * sqrt_a > igso_min_axis_m) .igso else .meo;
}

pub fn almanacTimeFits(t: time.GpsTime) bool {
    const bdt = t.inScale(.bds);
    return bdt.sub_ms == 0 and bdt.ms % almanac_reference.toa_step_ms == 0;
}

pub const D1d2Extra = struct {
    pub const transmission_lead_s: ?f64 = null;
    pub const almanac_health_bits: u9 = health.almanac_health_all;
    ura_index: u4,
    sat_h1: bool,
    aodc: u5,
    aode: u5,

    pub fn signalStatus(self: D1d2Extra, _: types.Signal) health.Status {
        return health.flagged(self.sat_h1);
    }

    pub fn healthy(_: D1d2Extra) bool {
        return true;
    }

    pub fn almanacHealth(self: D1d2Extra) u9 {
        return if (self.sat_h1) health.almanac_health_all else 0;
    }
};

pub const BcnavSignalFlags = struct {
    dif: bool,
    sif: bool,
    aif: bool,
};

pub const BcnavExtra = struct {
    pub const transmission_lead_s: ?f64 = null;
    pub const almanac_health_bits: u9 = health.almanac_health_all;
    sat_type: ?SatType,
    sismai: u4,
    sisai_oe: u5,
    sisai_ocb: u5,
    sisai_oc1: u3,
    sisai_oc2: u3,
    b1c: ?BcnavSignalFlags,
    b2a: ?BcnavSignalFlags,
    b2b: ?BcnavSignalFlags,
    hs_b1c: bool,
    hs_b2a: bool,
    hs_b2b: bool,

    pub fn signalStatus(self: BcnavExtra, signal: types.Signal) health.Status {
        const bad = switch (signal) {
            .b1c => self.hs_b1c,
            .b2a => self.hs_b2a,
            .b2b => self.hs_b2b,
            else => return .unstated,
        };
        return health.flagged(bad);
    }

    pub fn healthy(_: BcnavExtra) bool {
        return true;
    }

    pub fn signalsBad(self: BcnavExtra) bool {
        return self.hs_b1c or self.hs_b2a or self.hs_b2b;
    }

    pub fn almanacHealth(self: BcnavExtra) u9 {
        return (@as(u9, @intFromBool(self.hs_b1c)) << 2) | (@as(u9, @intFromBool(self.hs_b2a)) << 1) | @intFromBool(self.hs_b2b);
    }
};
