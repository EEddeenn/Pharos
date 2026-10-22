const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const kepler_parameters = @import("domain/navigation/orbit/parameters");
const health = @import("domain/navigation/health");
const gps_records = @import("domain/navigation/records/gps");
const galileo_records = @import("domain/navigation/records/galileo");
const bds_records = @import("domain/navigation/records/bds");
const glonass_records = @import("domain/navigation/records/glonass");

const ClockPoly = @import("domain/time/clock").Poly;

const SatId = gnss_types.SatId;
const System = gnss_types.System;
const Signal = gnss_types.Signal;
const GpsTime = time.GpsTime;

pub const NavSource = enum {
    lnav,
    cnav,
    cnav2,
    d1d2,
    bcnav1,
    bcnav2,
    bcnav3,
    inav,
    fnav,

    pub fn rinexName(self: NavSource, sat: SatId) []const u8 {
        return switch (self) {
            .lnav => "LNAV",
            .cnav => "CNAV",
            .cnav2 => "CNV2",
            .d1d2 => if (bds_records.isGeo(sat.prn())) "D2" else "D1",
            .bcnav1 => "CNV1",
            .bcnav2 => "CNV2",
            .bcnav3 => "CNV3",
            .inav => "INAV",
            .fnav => "FNAV",
        };
    }

    pub fn family(self: NavSource) gnss_types.NavFamily {
        return switch (self) {
            inline else => |tag| @field(gnss_types.NavFamily, @tagName(tag)),
        };
    }

    pub fn weekScale(self: NavSource) time.WeekScale {
        return switch (self) {
            .lnav, .cnav, .cnav2 => .gps,
            .d1d2, .bcnav1, .bcnav2, .bcnav3 => .bds,
            .inav, .fnav => .gal,
        };
    }

    pub fn system(self: NavSource) gnss_types.System {
        return switch (self.weekScale()) {
            .gps => .gps,
            .bds => .bds,
            .gal => .gal,
        };
    }
};

pub const GroupDelayTerm = enum {
    tgd_l1ca,
    isc_l1ca,
    isc_l1cd,
    isc_l1cp,
    isc_l2c,
    isc_l5i5,
    isc_l5q5,
    tgd_b1cp,
    isc_b1cd,
    tgd_b2ap,
    isc_b2ad,
    tgd_b2bi,
    tgd_b1i,
    tgd_b2i,
    bgd_e1e5a,
    bgd_e1e5b,
    delta_tau_n,

    /// Each term as a sentence names it: as the message tables name its field.
    pub const words: std.EnumArray(GroupDelayTerm, [:0]const u8) = .init(.{ .tgd_l1ca = "tgd", .isc_l1ca = "isc_l1ca", .isc_l1cd = "isc_l1cd", .isc_l1cp = "isc_l1cp", .isc_l2c = "isc_l2c", .isc_l5i5 = "isc_l5i5", .isc_l5q5 = "isc_l5q5", .tgd_b1cp = "tgd_b1cp", .isc_b1cd = "isc_b1cd", .tgd_b2ap = "tgd_b2ap", .isc_b2ad = "isc_b2ad", .tgd_b2bi = "tgd_b2bi", .tgd_b1i = "tgd1", .tgd_b2i = "tgd2", .bgd_e1e5a = "bgd_e1e5a", .bgd_e1e5b = "bgd_e1e5b", .delta_tau_n = "delta_tau_n" });
};

pub const GroupDelays = std.EnumMap(GroupDelayTerm, f64);

pub const SourceExtra = union(NavSource) {
    lnav: gps_records.LnavExtra,
    cnav: gps_records.CnavExtra,
    cnav2: gps_records.Cnav2Extra,
    d1d2: bds_records.D1d2Extra,
    bcnav1: bds_records.BcnavExtra,
    bcnav2: bds_records.BcnavExtra,
    bcnav3: bds_records.BcnavExtra,
    inav: galileo_records.InavExtra,
    fnav: galileo_records.FnavExtra,

    pub fn healthy(self: SourceExtra) bool {
        return switch (self) {
            inline else => |x| x.healthy(),
        };
    }

    pub fn signalStatus(self: SourceExtra, signal: Signal) health.Status {
        return switch (self) {
            inline else => |x| x.signalStatus(signal),
        };
    }

    pub fn transmissionLead(self: SourceExtra) ?f64 {
        return switch (self) {
            inline else => |x| @TypeOf(x).transmission_lead_s,
        };
    }

    pub fn almanacHealth(self: SourceExtra) u9 {
        return switch (self) {
            inline else => |x| x.almanacHealth(),
        };
    }

    pub fn almanacHealthBits(self: SourceExtra) u9 {
        return switch (self) {
            inline else => |x| @TypeOf(x).almanac_health_bits,
        };
    }
};

pub const epoch_step_ms = kepler_parameters.epoch_step_ms;
pub const epoch_step_s = kepler_parameters.epoch_step_s;
const issue_modulus = 256;

pub const KeplerEphemeris = struct {
    sat: SatId,
    iode: u16,
    iodc: u16,
    toe: GpsTime,
    toc: GpsTime,
    top: ?GpsTime,
    transmitted: ?GpsTime,
    m0: f64,
    delta_n: f64,
    delta_n_dot: f64,
    ecc: f64,
    sqrt_a: f64,
    a_dot: f64,
    omega0: f64,
    i0: f64,
    w: f64,
    omega_dot: f64,
    idot: f64,
    cuc: f64,
    cus: f64,
    crc: f64,
    crs: f64,
    cic: f64,
    cis: f64,
    af0: f64,
    af1: f64,
    af2: f64,
    group_delay: GroupDelays,
    extra: SourceExtra,

    pub fn system(self: KeplerEphemeris) System {
        return self.sat.system;
    }

    pub fn source(self: KeplerEphemeris) NavSource {
        return self.extra;
    }

    pub fn weekScale(self: KeplerEphemeris) time.WeekScale {
        return self.source().weekScale();
    }

    pub fn clock(self: *const KeplerEphemeris) ClockPoly {
        return self.parameters().clock();
    }

    pub fn parameters(self: *const KeplerEphemeris) kepler_parameters.Parameters {
        var out: kepler_parameters.Parameters = undefined;
        inline for (@typeInfo(kepler_parameters.Parameters).@"struct".field_names) |name| @field(out, name) = @field(self, name);
        return out;
    }
};

pub const GlonassEphemeris = glonass_records.GlonassEphemeris;
pub const GlonassAlmanac = glonass_records.GlonassAlmanac;

pub const KeplerAlmanac = struct {
    sat: SatId,
    toa: GpsTime,
    health: u9,
    iod: u8,
    carriers: ?u3 = null,
    ecc: f64,
    sqrt_a: f64,
    omega0: f64,
    i0: f64,
    w: f64,
    omega_dot: f64,
    m0: f64,
    af0: f64,
    af1: f64,
};

pub const Almanac = union(enum) {
    kepler: KeplerAlmanac,
    glonass: GlonassAlmanac,

    pub fn sat(self: Almanac) SatId {
        return switch (self) {
            .kepler => |k| k.sat,
            .glonass => |g| g.sat,
        };
    }
};

pub const Ephemerides = struct {
    kepler: []const KeplerEphemeris = &.{},
    glonass: []const GlonassEphemeris = &.{},
};

pub fn issueOfEpoch(t: GpsTime, scale: time.WeekScale) u16 {
    return @intCast(@mod(@divFloor(t.inScale(scale).ms, epoch_step_ms), issue_modulus));
}
