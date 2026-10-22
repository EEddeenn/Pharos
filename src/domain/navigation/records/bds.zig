const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const auxiliary = @import("domain/navigation/system_data");
const health = @import("domain/navigation/health");
const almanac_reference = @import("domain/navigation/almanac_epoch");

pub const BdtLeap = struct { delta_tls: i16, delta_tlsf: i16, wn_lsf: u16, dn: i16 };

pub const SatType = enum(u2) { geo = 1, igso = 2, meo = 3 };

const igso_min_axis_m = 4.0e7;

pub const D1d2Extra = struct {
    ura_index: u4,
    sat_h1: bool,
    aodc: u5,
    aode: u5,

    pub const transmission_lead_s: ?f64 = null;
    pub const almanac_health_bits: u9 = health.almanac_health_all;

    pub fn signalStatus(self: D1d2Extra, _: gnss_types.Signal) health.Status {
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
    sat_type: SatType,
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

    pub const transmission_lead_s: ?f64 = null;
    pub const almanac_health_bits: u9 = health.almanac_health_all;

    /// SIF, the health of its own signal (BDS-OS-PS 3.0 5.3.3.2); HS describes the whole satellite.
    pub fn signalStatus(self: BcnavExtra, signal: gnss_types.Signal) health.Status {
        const flags = switch (signal) {
            .b1c => self.b1c,
            .b2a => self.b2a,
            .b2b => self.b2b,
            else => null,
        } orelse return .unstated;
        return health.flagged(flags.sif);
    }

    pub fn healthy(_: BcnavExtra) bool {
        return true;
    }

    pub fn signalsBad(self: BcnavExtra) bool {
        return self.hs_b1c or self.hs_b2a or self.hs_b2b;
    }

    pub fn almanacHealth(self: BcnavExtra) u9 {
        return if (self.signalsBad()) health.almanac_health_all else 0;
    }
};

pub fn bdtLeap(leap: auxiliary.LeapSecondSchedule) ?BdtLeap {
    if (leap.wn_lsf < time.bds_week_offset) return null;
    return projectBdtLeap(leap);
}

pub fn projectBdtLeap(leap: auxiliary.LeapSecondSchedule) BdtLeap {
    const current: i16 = leap.delta_tls;
    const future: i16 = leap.delta_tlsf;
    const day: i16 = leap.dn;
    const epoch_week: u16 = time.bds_week_offset;
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

pub fn satTypeOf(prn: u8, sqrt_a: f64) SatType {
    if (isGeo(prn)) return .geo;
    return if (sqrt_a * sqrt_a > igso_min_axis_m) .igso else .meo;
}

pub fn almanacTimeFits(t: time.GpsTime) bool {
    const bdt = t.inScale(.bds);
    return bdt.sub_ms == 0 and bdt.ms % almanac_reference.toa_step_ms == 0;
}
