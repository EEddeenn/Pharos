pub const light_speed: f64 = 299792458.0;
pub const pi: f64 = 3.14159265358979323846264338328;
pub const two_pi: f64 = 2.0 * pi;

pub const earth_gm: f64 = 3.986004418e14;

pub fn rad2deg(r: f64) f64 {
    return r * (180.0 / pi);
}

pub fn deg2rad(d: f64) f64 {
    return d * (pi / 180.0);
}

pub const wgs_axis_a: f64 = 6378137.0;
pub const wgs_axis_b: f64 = 6356752.3142451795;
pub const wgs_e1_sqr: f64 = 0.006694379990141317;
pub const wgs_e2_sqr: f64 = 0.006739496742276435;

pub const iono_reference_hz: u32 = 1_575_420_000;

pub const SystemConstants = struct {
    mu: f64,
    omega_e: f64,
};
