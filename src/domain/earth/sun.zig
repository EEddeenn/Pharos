const coordinates = @import("domain/earth/coordinates");
const angles = @import("base/math/angles");

const GpsTime = @import("domain/time/gps").GpsTime;

const au_m: f64 = 149_597_870_700.0;
const jd_gps_epoch: f64 = 2_444_244.5;
const jd_j2000: f64 = 2_451_545.0;
const tt_minus_gps_s: f64 = 51.184;

pub fn positionEcef(t: GpsTime) coordinates.Ecef {
    const gps_days = (@as(f64, @floatFromInt(t.ms)) + t.sub_ms) / 86_400_000.0;
    const n = gps_days + jd_gps_epoch - jd_j2000 + tt_minus_gps_s / 86_400.0;
    const mean_longitude = @mod(280.460 + 0.9856474 * n, 360.0);
    const g = angles.deg2rad(@mod(357.528 + 0.9856003 * n, 360.0));
    const lambda = angles.deg2rad(mean_longitude + 1.915 * @sin(g) + 0.020 * @sin(2.0 * g));
    const obliquity = angles.deg2rad(23.439 - 0.0000004 * n);
    const r = (1.00014 - 0.01671 * @cos(g) - 0.00014 * @cos(2.0 * g)) * au_m;
    const x = r * @cos(lambda);
    const y = r * @cos(obliquity) * @sin(lambda);
    const z = r * @sin(obliquity) * @sin(lambda);
    const leap: f64 = @floatFromInt(t.leap(.table).count);
    const ut1_days = gps_days - leap / 86_400.0 + jd_gps_epoch - jd_j2000;
    const gmst = angles.deg2rad(@mod(280.46061837 + 360.98564736629 * ut1_days, 360.0));
    return .{ .x = x * @cos(gmst) + y * @sin(gmst), .y = -x * @sin(gmst) + y * @cos(gmst), .z = z };
}
