const core = @import("shared").core;
const model = @import("model.zig");

/// A place given in degrees and metres of the plan's altitude reference, in WGS84 coordinates: its height the
/// ellipsoidal one.
pub fn lla(latitude_deg: f64, longitude_deg: f64, altitude_m: f64, altitude: model.Altitude) core.coord.Lla {
    const lat = core.constants.deg2rad(latitude_deg);
    const lon = core.constants.deg2rad(longitude_deg);
    return switch (altitude) {
        .egm96 => core.geoid.lla(lat, lon, altitude_m),
        .ellipsoid => .{ .lat_rad = lat, .lon_rad = lon, .height_m = altitude_m },
    };
}
