const model = @import("products/traj/input/model");
const angles = @import("base/math/angles");
const coordinates = @import("domain/earth/coordinates");
const geoid = @import("domain/earth/geoid/model");

/// A place given in degrees and metres of the plan's altitude reference, in WGS84 coordinates: its height the
/// ellipsoidal one.
pub fn lla(latitude_deg: f64, longitude_deg: f64, altitude_m: f64, altitude: model.Altitude) coordinates.Lla {
    const lat = angles.deg2rad(latitude_deg);
    const lon = angles.deg2rad(longitude_deg);
    return switch (altitude) {
        .egm96 => geoid.lla(lat, lon, altitude_m),
        .ellipsoid => .{ .lat_rad = lat, .lon_rad = lon, .height_m = altitude_m },
    };
}
