const civil = @import("domain/time/civil");
const gpt3 = @import("domain/propagation/troposphere/gpt3");
const vmf3 = @import("domain/propagation/troposphere/vmf3");
const angles = @import("base/math/angles");

const Lla = @import("domain/earth/coordinates").Lla;
const GpsTime = @import("domain/time/gps").GpsTime;

const min_elevation_rad: f64 = 3.0 * angles.pi / 180.0;

const water_molar_mass_g_per_mol = 18.0152;
const dry_air_molar_mass_g_per_mol = 28.9644;
const gravity_lat_factor = 0.00266;
const gravity_height_factor_per_m = 0.28e-6;
const gravity_height_cap_m = 11000.0;
const hydrostatic_m_per_hpa = 0.0022768;
const refractivity_scale = 1e-6;

pub const Site = struct {
    zenith: Zenith,
    mapping: vmf3.MappingCoefficients,
    height_m: f64,
};

const Zenith = struct { hydrostatic: f64, wet: f64 };

pub fn site(t: GpsTime, rx: Lla) Site {
    const doy = dayOfYear(t);
    const met = gpt3.meteorology(doy, rx);
    return .{
        .zenith = zenith(met, rx.lat_rad, rx.height_m),
        .mapping = vmf3.coefficients(doy, rx, met.ah, met.aw),
        .height_m = rx.height_m,
    };
}

pub fn delay(s: Site, el_rad: f64) f64 {
    if (el_rad <= 0) return 0.0;
    const m = vmf3.map(s.mapping, @max(el_rad, min_elevation_rad), s.height_m);
    return s.zenith.hydrostatic * m.hydrostatic + s.zenith.wet * m.wet;
}

fn zenith(met: gpt3.Meteorology, lat_rad: f64, height_m: f64) Zenith {
    const k1 = 77.604;
    const k2 = 64.79;
    const k3 = 377600.0;
    const k2_prime = k2 - k1 * water_molar_mass_g_per_mol / dry_air_molar_mass_g_per_mol;
    const gravity = gpt3.gravity_mps2;
    const rd = gpt3.gas_constant_j_per_mol_k / gpt3.dry_air_molar_mass_kg_per_mol;
    const f = 1 - gravity_lat_factor * @cos(2 * lat_rad) - gravity_height_factor_per_m * @min(height_m, gravity_height_cap_m);
    return .{
        .hydrostatic = hydrostatic_m_per_hpa * met.pressure / f,
        .wet = refractivity_scale * (k2_prime + k3 / met.mean_temp) * rd / (met.lambda + 1) / gravity * met.vapour,
    };
}

fn dayOfYear(t: GpsTime) f64 {
    const year = t.toCalendar().year;
    const days = @divFloor(t.ms, civil.ms_per_day) - @divFloor(civil.calendarMs(year, 1, 1, 0), civil.ms_per_day);
    const into_day = @as(f64, @floatFromInt(@mod(t.ms, civil.ms_per_day))) + t.sub_ms;
    return @as(f64, @floatFromInt(days + 1)) + into_day / civil.ms_per_day;
}
