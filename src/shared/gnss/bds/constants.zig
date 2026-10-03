const std = @import("std");
const constants = @import("../../core.zig").constants;
const SatType = @import("records.zig").SatType;

pub const orbit: constants.SystemConstants = .{
    .mu = 3.986004418e14,
    .omega_e = 7.292115e-5,
};

const a_ref_meo: f64 = 27_906_100.0;
const a_ref_geo_igso: f64 = 42_162_200.0;
const nominal_i0: f64 = 0.3 * std.math.pi;

pub fn almanacInclinationReference(geo: bool) f64 {
    return if (geo) 0.0 else nominal_i0;
}

pub fn aRef(t: SatType) f64 {
    return if (t == .meo) a_ref_meo else a_ref_geo_igso;
}
