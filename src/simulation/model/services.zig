const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const bds_records = @import("domain/navigation/records/bds");
const Payload = @import("domain/signals/payload").Payload;
const Config = @import("simulation/model/config").Config;
const Publications = @import("simulation/model/publications").Publications;

pub const Service = enum { has, ppp_b2b, d2, gps_differential };

pub const ServicePlan = struct {
    active: std.EnumSet(Service) = .empty,

    pub fn init(config: *const Config, publications: *const Publications, payload: *const Payload, has_precise: bool) ServicePlan {
        var out: ServicePlan = .{};
        if (config.samples == null) return out;
        const families = payload.families(config.signals);
        if (config.has != null and families.contains(.cnav_has)) out.active.insert(.has);
        if (config.ppp_b2b != null and families.contains(.ppp_b2b)) out.active.insert(.ppp_b2b);
        if (publications.d2.len != 0 and carriesD2(payload, config.signals)) out.active.insert(.d2);
        if (has_precise and publications.declaresDifferential() and (families.contains(.cnav) or families.contains(.cnav2))) out.active.insert(.gps_differential);
        return out;
    }

    pub fn runs(self: ServicePlan, service: Service) bool {
        return self.active.contains(service);
    }
};

fn carriesD2(payload: *const Payload, signals: std.EnumSet(gnss_types.Signal)) bool {
    var sats = gnss_types.System.bds.satellites();
    while (sats.next()) |sat| {
        if (!bds_records.isGeo(sat.prn())) continue;
        var listed = signals.iterator();
        while (listed.next()) |signal| if (payload.familyOf(sat, signal) == .d1d2) return true;
    }
    return false;
}
