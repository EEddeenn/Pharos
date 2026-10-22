const std = @import("std");
const angles = @import("base/math/angles");

const earth_radius_km: f64 = 6371.2;
const coincident_deg: f64 = 1e-5;
const pole_tolerance_deg: f64 = 1e-10;
const vertical_perigee_km: f64 = 0.1;
const split_low_km: f64 = 1000.0;
const split_high_km: f64 = 2000.0;

pub const Point = struct { lat_deg: f64, lon_deg: f64, h_km: f64 };
pub const Error = error{InvalidRay};

pub const Ray = struct {
    from_height_km: f64,
    until_height_km: f64,
    geometry: union(enum) { vertical, slant: Slant },

    pub fn between(p1: Point, p2: Point) Error!Ray {
        const longitude_delta = @mod(p2.lon_deg - p1.lon_deg + 180.0, 360.0) - 180.0;
        if (@abs(p2.lat_deg - p1.lat_deg) < coincident_deg and @abs(longitude_delta) < coincident_deg) {
            return .{ .from_height_km = p1.h_km, .until_height_km = p2.h_km, .geometry = .vertical };
        }
        const r1 = p1.h_km + earth_radius_km;
        const r2 = p2.h_km + earth_radius_km;
        const lat1 = angles.deg2rad(p1.lat_deg);
        const lat2 = angles.deg2rad(p2.lat_deg);
        const s1 = @sin(lat1);
        const c1 = @cos(lat1);
        const s2 = @sin(lat2);
        const c2 = @cos(lat2);
        const dl = angles.deg2rad(p2.lon_deg - p1.lon_deg);
        const cos_del = std.math.clamp(s1 * s2 + c1 * c2 * @cos(dl), -1.0, 1.0);
        const sin_del = @sqrt(1.0 - cos_del * cos_del);
        const zeta = std.math.atan2(sin_del, cos_del - r1 / r2);
        const zeta_deg = angles.rad2deg(zeta);
        const rp = r1 * @sin(zeta);
        var lat_p_deg: f64 = undefined;
        var lon_p_deg: f64 = undefined;
        if (@abs(@abs(p1.lat_deg) - 90.0) < pole_tolerance_deg) {
            lat_p_deg = if (p1.lat_deg > 0) zeta_deg else -zeta_deg;
            lon_p_deg = if (zeta >= 0) p2.lon_deg + 180.0 else p2.lon_deg;
        } else {
            const sin_sig = @sin(dl) * c2 / sin_del;
            const cos_sig = (s2 - cos_del * s1) / (sin_del * c1);
            const delp = std.math.pi / 2.0 - zeta;
            const sin_delp = @sin(delp);
            const cos_delp = @cos(delp);
            const sin_php = std.math.clamp(s1 * cos_delp - c1 * sin_delp * cos_sig, -1.0, 1.0);
            const cos_php = @sqrt(1.0 - sin_php * sin_php);
            lat_p_deg = angles.rad2deg(std.math.atan2(sin_php, cos_php));
            const sin_lamp = -sin_sig * sin_delp / cos_php;
            const cos_lamp = (cos_delp - s1 * sin_php) / (c1 * cos_php);
            lon_p_deg = angles.rad2deg(std.math.atan2(sin_lamp, cos_lamp)) + p1.lon_deg;
        }
        if (@abs(zeta_deg) > 90.0 and rp < earth_radius_km) return error.InvalidRay;
        if (rp < vertical_perigee_km) return .{ .from_height_km = p1.h_km, .until_height_km = p2.h_km, .geometry = .vertical };
        const sin_lat_p = @sin(angles.deg2rad(lat_p_deg));
        const cos_lat_p = @cos(angles.deg2rad(lat_p_deg));
        const delta_long = angles.deg2rad(p2.lon_deg - lon_p_deg);
        const direction: [2]f64 = if (@abs(@abs(lat_p_deg) - 90.0) < pole_tolerance_deg)
            .{ 0, if (lat_p_deg > 0) -1.0 else 1.0 }
        else blk: {
            const cos_psi = std.math.clamp(sin_lat_p * s2 + cos_lat_p * c2 * @cos(delta_long), -1.0, 1.0);
            const sin_psi = @sqrt(1.0 - cos_psi * cos_psi);
            break :blk .{ c2 * @sin(delta_long) / sin_psi, (s2 - sin_lat_p * cos_psi) / (sin_psi * cos_lat_p) };
        };
        return .{
            .from_height_km = p1.h_km,
            .until_height_km = p2.h_km,
            .geometry = .{ .slant = .{ .perigee_radius_km = rp, .perigee_lon_deg = lon_p_deg, .sin_lat_p = sin_lat_p, .cos_lat_p = cos_lat_p, .sin_sig = direction[0], .cos_sig = direction[1] } },
        };
    }
};

pub const Slant = struct {
    perigee_radius_km: f64,
    perigee_lon_deg: f64,
    sin_lat_p: f64,
    cos_lat_p: f64,
    sin_sig: f64,
    cos_sig: f64,

    pub fn pointAt(self: *const Slant, s_km: f64) Point {
        const tan_del = s_km / self.perigee_radius_km;
        const cos_del = 1.0 / @sqrt(1.0 + tan_del * tan_del);
        const sin_del = tan_del * cos_del;
        const arg = std.math.clamp(self.sin_lat_p * cos_del + self.cos_lat_p * sin_del * self.cos_sig, -1.0, 1.0);
        const lat = angles.rad2deg(std.math.atan2(arg, @sqrt(1.0 - arg * arg)));
        const clong = angles.rad2deg(std.math.atan2(sin_del * self.sin_sig * self.cos_lat_p, cos_del - self.sin_lat_p * arg));
        return .{ .lat_deg = lat, .lon_deg = clong + self.perigee_lon_deg, .h_km = @sqrt(s_km * s_km + self.perigee_radius_km * self.perigee_radius_km) - earth_radius_km };
    }

    fn distanceOf(self: *const Slant, r_km: f64) f64 {
        return @sqrt(r_km * r_km - self.perigee_radius_km * self.perigee_radius_km);
    }
};

const tolerance_low: f64 = 1e-3;
const tolerance_high: f64 = 1e-2;

pub fn integrate(ray: *const Ray, ctx: anytype, comptime f: fn (@TypeOf(ctx), f64) f64) f64 {
    const h1 = ray.from_height_km;
    const h2 = ray.until_height_km;
    const x1 = coordinate(ray, @max(h1, 0.0));
    const x2 = coordinate(ray, h2);
    const low = tolerance_low;
    const high = tolerance_high;
    if (h2 <= split_low_km) return kronrod(ctx, f, x1, x2, low, 0);
    const xa = coordinate(ray, split_low_km);
    if (h2 <= split_high_km) {
        if (h1 >= split_low_km) return kronrod(ctx, f, x1, x2, high, 0);
        return kronrod(ctx, f, x1, xa, low, 0) + kronrod(ctx, f, xa, x2, high, 0);
    }
    if (h1 >= split_high_km) return kronrod(ctx, f, x1, x2, high, 0);
    const xb = coordinate(ray, split_high_km);
    if (h1 >= split_low_km) return kronrod(ctx, f, x1, xb, high, 0) + kronrod(ctx, f, xb, x2, high, 0);
    return kronrod(ctx, f, x1, xa, low, 0) + kronrod(ctx, f, xa, xb, high, 0) + kronrod(ctx, f, xb, x2, high, 0);
}

fn coordinate(ray: *const Ray, h_km: f64) f64 {
    return switch (ray.geometry) {
        .vertical => h_km,
        .slant => |*slant| slant.distanceOf(h_km + earth_radius_km),
    };
}

fn kronrod(ctx: anytype, comptime f: fn (@TypeOf(ctx), f64) f64, g1: f64, g2: f64, tol: f64, level: u32) f64 {
    const max_level = 50;
    const wi = [15]f64{ 0.022935322010529224963732008058970, 0.063092092629978553290700663189204, 0.104790010322250183839876322541518, 0.140653259715525918745189590510238, 0.169004726639267902826583426598550, 0.190350578064785409913256402421014, 0.204432940075298892414161999234649, 0.209482141084727828012999174891714, 0.204432940075298892414161999234649, 0.190350578064785409913256402421014, 0.169004726639267902826583426598550, 0.140653259715525918745189590510238, 0.104790010322250183839876322541518, 0.063092092629978553290700663189204, 0.022935322010529224963732008058970 };
    const wig = [7]f64{ 0.129484966168869693270611432679082, 0.279705391489276667901467771423780, 0.381830050505118944950369775488975, 0.417959183673469387755102040816327, 0.381830050505118944950369775488975, 0.279705391489276667901467771423780, 0.129484966168869693270611432679082 };
    const xi = [15]f64{ -0.991455371120812639206854697526329, -0.949107912342758524526189684047851, -0.864864423359769072789712788640926, -0.741531185599394439863864773280788, -0.586087235467691130294144838258730, -0.405845151377397166906606412076961, -0.207784955007898467600689403773245, 0.0, 0.207784955007898467600689403773245, 0.405845151377397166906606412076961, 0.586087235467691130294144838258730, 0.741531185599394439863864773280788, 0.864864423359769072789712788640926, 0.949107912342758524526189684047851, 0.991455371120812639206854697526329 };
    const h2 = (g2 - g1) / 2.0;
    const hh = (g2 + g1) / 2.0;
    var intk: f64 = 0;
    var intg: f64 = 0;
    for (0..15) |i| {
        const y = f(ctx, h2 * xi[i] + hh);
        intk += y * wi[i];
        if (i % 2 == 1) intg += y * wig[i / 2];
    }
    intk *= h2;
    intg *= h2;
    if (@abs((intk - intg) / intk) <= tol or @abs(intk - intg) <= tol or level >= max_level) return intk;
    return kronrod(ctx, f, g1, hh, tol, level + 1) + kronrod(ctx, f, hh, g2, tol, level + 1);
}
