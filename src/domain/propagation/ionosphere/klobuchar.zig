const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const shell = @import("domain/propagation/ionosphere/shell");
const time = @import("domain/time/gps");
const angles = @import("base/math/angles");
const physical = @import("domain/physical_constants");

const GpsTime = time.GpsTime;

const min_period_s = 72000.0;
const max_period_s = 172800.0;
const peak_local_s = 50400.0;
const night_delay_s = 5e-9;
const s_per_semicircle = 43200.0;

pub const Model = struct {
    alpha: [4]f64,
    beta: [4]f64,

    pub const zero: Model = .{ .alpha = .{ 0, 0, 0, 0 }, .beta = .{ 0, 0, 0, 0 } };

    pub const default_broadcast: Model = .{
        .alpha = .{ 0.111758708953857421875e-07, 0.22351741790771484375e-07, -0.11920928955078125e-06, -0.11920928955078125e-06 },
        .beta = .{ 0.116736e+06, 0.114688e+06, -0.131072e+06, -0.1048576e+07 },
    };
};

pub const Prepared = struct {
    coefficients: Model,
    tow_s: f64,
    latitude: f64,
    longitude: f64,
    height_m: f64,

    const layer_height_m = 350.0e3;

    pub fn at(model: Model, t: GpsTime, rx: coordinates.Lla) Prepared {
        return .{
            .coefficients = model,
            .tow_s = t.sow(),
            .latitude = rx.lat_rad / angles.pi,
            .longitude = rx.lon_rad / angles.pi,
            .height_m = rx.height_m,
        };
    }

    pub fn delayL1(self: *const Prepared, _: coordinates.Ecef, el_rad: f64, az_rad: f64) f64 {
        const pi = angles.pi;
        const el = (shell.elevation(layer_height_m, self.height_m, el_rad) orelse return 0) / pi;
        var lat = self.latitude;
        var lon = self.longitude;
        const psi = 0.0137 / (el + 0.11) - 0.022;
        lat = std.math.clamp(lat + psi * @cos(az_rad), -0.416, 0.416);
        lon += psi * @sin(az_rad) / @cos(lat * pi);
        lat += 0.064 * @cos((lon - 1.617) * pi);
        const f = (1.0 + 16.0 * std.math.pow(f64, 0.53 - el, 3)) * physical.light_speed;
        const period = @max(self.coefficients.beta[0] + (self.coefficients.beta[1] + (self.coefficients.beta[2] + self.coefficients.beta[3] * lat) * lat) * lat, min_period_s);
        const local_s = @mod(s_per_semicircle * lon + self.tow_s, time.s_per_day);
        const x = 2.0 * pi * (local_s - peak_local_s) / period;
        if (x >= 1.57 or x <= -1.57) return f * night_delay_s;
        const amp = self.coefficients.alpha[0] + (self.coefficients.alpha[1] + (self.coefficients.alpha[2] + self.coefficients.alpha[3] * lat) * lat) * lat;
        if (amp < 0) return f * night_delay_s;
        const x2 = x * x;
        return f * (night_delay_s + amp * (1.0 - x2 / 2.0 + x2 * x2 / 24.0));
    }
};

pub const BdsPrepared = struct {
    coefficients: Model,
    seconds: f64,
    sin_latitude: f64,
    cos_latitude: f64,
    longitude: f64,
    height_m: f64,

    const earth_radius_m = 6378.0e3;
    const layer_height_m = 375.0e3;
    const b1i_hz = 1561.098e6;

    pub fn at(model: Model, t: GpsTime, rx: coordinates.Lla) BdsPrepared {
        return .{
            .coefficients = model,
            .seconds = t.inScale(.bds).asF64Seconds(),
            .sin_latitude = @sin(rx.lat_rad),
            .cos_latitude = @cos(rx.lat_rad),
            .longitude = rx.lon_rad,
            .height_m = rx.height_m,
        };
    }

    pub fn delayL1(self: *const BdsPrepared, _: coordinates.Ecef, el_rad: f64, az_rad: f64) f64 {
        const pi = angles.pi;
        const el = shell.elevation(layer_height_m, self.height_m, el_rad) orelse return 0;
        const k = earth_radius_m / (earth_radius_m + layer_height_m) * @cos(el);
        const psi = pi / 2.0 - el - std.math.asin(k);
        const lat = std.math.asin(std.math.clamp(self.sin_latitude * @cos(psi) + self.cos_latitude * @sin(psi) * @cos(az_rad), -1.0, 1.0));
        const lon = self.longitude + std.math.asin(std.math.clamp(@sin(psi) * @sin(az_rad) / @cos(lat), -1.0, 1.0));
        const phi = @abs(lat) / pi;
        const c = self.coefficients;
        const amplitude = @max(c.alpha[0] + (c.alpha[1] + (c.alpha[2] + c.alpha[3] * phi) * phi) * phi, 0.0);
        const period = std.math.clamp(c.beta[0] + (c.beta[1] + (c.beta[2] + c.beta[3] * phi) * phi) * phi, min_period_s, max_period_s);
        const local_s = @mod(self.seconds + lon * s_per_semicircle / pi, time.s_per_day);
        const from_peak = local_s - peak_local_s;
        const vertical_s = if (@abs(from_peak) < period / 4.0) night_delay_s + amplitude * @cos(2.0 * pi * from_peak / period) else night_delay_s;
        const ratio = b1i_hz / @as(f64, physical.iono_reference_hz);
        return vertical_s / @sqrt(1.0 - k * k) * physical.light_speed * ratio * ratio;
    }
};
