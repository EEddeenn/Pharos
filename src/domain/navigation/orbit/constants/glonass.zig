const orbit_constants = @import("domain/navigation/orbit/constants");

pub const pz90_ae: f64 = 6378136.0;
pub const pz90_ae2: f64 = pz90_ae * pz90_ae;
pub const pz90_gm: f64 = 3.9860044e+14;
pub const pz90_j02: f64 = 1082625.7e-9;
pub const pz90_c20: f64 = 1082.63e-6;
pub const pz90_omegdote: f64 = 7.292115e-5;

pub const orbit: orbit_constants.SystemConstants = .{
    .mu = pz90_gm,
    .omega_e = pz90_omegdote,
};
