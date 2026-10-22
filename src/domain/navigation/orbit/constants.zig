const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const gps = @import("domain/navigation/orbit/constants/gps");
const bds = @import("domain/navigation/orbit/constants/bds");
const galileo = @import("domain/navigation/orbit/constants/galileo");
const glonass = @import("domain/navigation/orbit/constants/glonass");

pub const SystemConstants = struct {
    mu: f64,
    omega_e: f64,
};

const table = std.EnumArray(gnss_types.System, SystemConstants).init(.{
    .gps = gps.orbit,
    .bds = bds.orbit,
    .gal = galileo.orbit,
    .glo = glonass.orbit,
});

pub fn get(system: gnss_types.System) *const SystemConstants {
    return table.getPtrConst(system);
}
