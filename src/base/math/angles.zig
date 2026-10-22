pub const pi: f64 = 3.14159265358979323846264338328;
pub const two_pi: f64 = 2.0 * pi;

pub fn rad2deg(r: f64) f64 {
    return r * (180.0 / pi);
}

pub fn deg2rad(d: f64) f64 {
    return d * (pi / 180.0);
}
