const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const shell = @import("domain/propagation/ionosphere/shell");
const time = @import("domain/time/gps");
const physical = @import("domain/physical_constants");

const GpsTime = time.GpsTime;

const shell_height_km: f64 = 400.0;
const earth_radius_km: f64 = 6378.0;
const pole_lat_rad: f64 = 80.27 * std.math.pi / 180.0;
const pole_lon_rad: f64 = -72.58 * std.math.pi / 180.0;
const bdt_epoch_mjd: f64 = 53736.0;

const Harmonic = struct { n: u8, m: i8 };

const broadcast_harmonics = [9]Harmonic{
    .{ .n = 0, .m = 0 }, .{ .n = 1, .m = 0 },  .{ .n = 1, .m = 1 }, .{ .n = 1, .m = -1 }, .{ .n = 2, .m = 0 },
    .{ .n = 2, .m = 1 }, .{ .n = 2, .m = -1 }, .{ .n = 2, .m = 2 }, .{ .n = 2, .m = -2 },
};

const predicted_harmonics = [17]Harmonic{
    .{ .n = 3, .m = 0 },  .{ .n = 3, .m = 1 }, .{ .n = 3, .m = -1 }, .{ .n = 3, .m = 2 }, .{ .n = 3, .m = -2 }, .{ .n = 3, .m = 3 }, .{ .n = 3, .m = -3 },
    .{ .n = 4, .m = 0 },  .{ .n = 4, .m = 1 }, .{ .n = 4, .m = -1 }, .{ .n = 4, .m = 2 }, .{ .n = 4, .m = -2 }, .{ .n = 5, .m = 0 }, .{ .n = 5, .m = 1 },
    .{ .n = 5, .m = -1 }, .{ .n = 5, .m = 2 }, .{ .n = 5, .m = -2 },
};

const periods_days = [12]f64{ 1.0, 0.5, 0.33, 14.6, 27.0, 121.6, 182.51, 365.25, 4028.71, 2014.35, 1342.90, 1007.18 };

const a0 = [17]f64{ -0.61, -1.31, -2.00, -0.03, 0.15, -0.48, -0.40, 2.28, -0.16, -0.21, -0.10, -0.13, 0.21, 0.68, 1.06, 0.0, -0.12 };

const Pierce = struct {
    sin_lat: f64,
    lon_rad: f64,
    mapping: f64,

    fn at(receiver: *const Prepared, el_rad: f64, az_rad: f64) Pierce {
        const ratio = earth_radius_km / (earth_radius_km + shell_height_km);
        const psi = std.math.pi / 2.0 - el_rad - std.math.asin(ratio * @cos(el_rad));
        const sin_u = receiver.sin_latitude;
        const cos_u = receiver.cos_latitude;
        const sin_g = std.math.clamp(sin_u * @cos(psi) + cos_u * @sin(psi) * @cos(az_rad), -1.0, 1.0);
        const lat_g = std.math.asin(sin_g);
        const lon_g = receiver.longitude + std.math.atan2(@sin(psi) * @sin(az_rad) * cos_u, @cos(psi) - sin_u * sin_g);
        const cos_g = @cos(lat_g);
        const dl = lon_g - pole_lon_rad;
        const sin_m = std.math.clamp(@sin(pole_lat_rad) * sin_g + @cos(pole_lat_rad) * cos_g * @cos(dl), -1.0, 1.0);
        const lon_m = std.math.atan2(cos_g * @sin(dl) * @cos(pole_lat_rad), @sin(pole_lat_rad) * sin_m - sin_g);
        const cos_e = ratio * @cos(el_rad);
        return .{ .sin_lat = sin_m, .lon_rad = lon_m - receiver.sun_longitude, .mapping = 1.0 / @sqrt(1.0 - cos_e * cos_e) };
    }
};

const prediction_period_h = 2.0;
const tec_delay_m_hz2 = 40.28e16;

pub const PredictionCache = struct {
    epoch: ?f64 = null,
    coefficients: [17]f64 = undefined,

    fn at(self: *PredictionCache, mjd: f64) *const [17]f64 {
        const epoch = predictionEpoch(mjd);
        if (self.epoch == null or self.epoch.? != epoch) {
            var sine: [periods_days.len]f64 = undefined;
            var cosine: [periods_days.len]f64 = undefined;
            for (periods_days, 0..) |period, k| {
                const arg = 2.0 * std.math.pi * epoch / period;
                sine[k] = @sin(arg);
                cosine[k] = @cos(arg);
            }
            for (&self.coefficients, 0..) |*coefficient, j| {
                var beta = a0[j];
                for (periods_days, 0..) |_, k| beta += a[k][j] * cosine[k] + b[k][j] * sine[k];
                coefficient.* = beta;
            }
            self.epoch = epoch;
        }
        return &self.coefficients;
    }
};

pub const Model = struct {
    alpha: [9]f64,
};

pub const Prepared = struct {
    alpha: [9]f64,
    beta: [17]f64,
    sin_latitude: f64,
    cos_latitude: f64,
    longitude: f64,
    height_m: f64,
    sun_longitude: f64,

    pub fn at(model: Model, t: GpsTime, rx: coordinates.Lla, cache: *PredictionCache) Prepared {
        const mjd = mjdOf(t);
        const s_lon = std.math.pi * (1.0 - 2.0 * (mjd - @floor(mjd)));
        const ds = s_lon - pole_lon_rad;
        return .{
            .alpha = model.alpha,
            .beta = cache.at(mjd).*,
            .sin_latitude = @sin(rx.lat_rad),
            .cos_latitude = @cos(rx.lat_rad),
            .longitude = rx.lon_rad,
            .height_m = rx.height_m,
            .sun_longitude = std.math.atan2(@sin(ds), @sin(pole_lat_rad) * @cos(ds)),
        };
    }

    pub fn delayL1(self: *const Prepared, _: coordinates.Ecef, el_rad: f64, az_rad: f64) f64 {
        const el = shell.elevation(shell_height_km * 1000.0, self.height_m, el_rad) orelse return 0;
        const p = Pierce.at(self, el, az_rad);
        return p.mapping * delayMetres(self.vtec(p), physical.iono_reference_hz);
    }

    fn vtec(self: *const Prepared, p: Pierce) f64 {
        const sin_lat = p.sin_lat;
        var sum: f64 = 0;
        for (predicted_harmonics, self.beta) |h, beta| sum += beta * basis(h, sin_lat, p.lon_rad);
        for (broadcast_harmonics, self.alpha) |h, coefficient| sum += coefficient * basis(h, sin_lat, p.lon_rad);
        return sum;
    }
};

fn normalizedLegendre(n: u8, m: u8, x: f64) f64 {
    std.debug.assert(m <= n);
    var pmm: f64 = 1.0;
    if (m > 0) {
        const s = @sqrt(1.0 - x * x);
        for (1..@as(usize, m) + 1) |k| pmm *= @as(f64, @floatFromInt(2 * k - 1)) * s;
    }
    var p_prev = pmm;
    var p: f64 = pmm;
    if (n > m) {
        p = @as(f64, @floatFromInt(2 * m + 1)) * x * pmm;
        for (@as(usize, m) + 2..@as(usize, n) + 1) |deg| {
            const d: f64 = @floatFromInt(deg);
            const mm: f64 = @floatFromInt(m);
            const next = ((2.0 * d - 1.0) * x * p - (d + mm - 1.0) * p_prev) / (d - mm);
            p_prev = p;
            p = next;
        }
    }
    const nf: f64 = @floatFromInt(n);
    const delta: f64 = if (m == 0) 1.0 else 0.0;
    const norm = @sqrt(factorial(n - m) * (2.0 * nf + 1.0) * (2.0 - delta) / factorial(n + m));
    return norm * p;
}

fn factorial(k: u8) f64 {
    var r: f64 = 1.0;
    for (0..k) |i| r *= @as(f64, @floatFromInt(i + 1));
    return r;
}

fn basis(h: Harmonic, sin_lat: f64, lon_rad: f64) f64 {
    const order = @abs(h.m);
    const p = normalizedLegendre(h.n, order, sin_lat);
    const arg = @as(f64, @floatFromInt(order)) * lon_rad;
    return if (h.m >= 0) p * @cos(arg) else p * @sin(arg);
}

fn mjdOf(t: GpsTime) f64 {
    const bdt = t.inScale(.bds);
    const seconds = @as(f64, @floatFromInt(bdt.period)) * time.s_per_week + bdt.asF64Seconds();
    return bdt_epoch_mjd + seconds / time.s_per_day;
}

fn predictionEpoch(mjd: f64) f64 {
    const day = @floor(mjd);
    const hour = (mjd - day) * 24.0;
    return day + (prediction_period_h * @floor(hour / prediction_period_h) + 1.0) / 24.0;
}

fn delayMetres(tecu: f64, carrier_hz: f64) f64 {
    return tec_delay_m_hz2 * tecu / (carrier_hz * carrier_hz);
}

const a = [12][17]f64{
    .{ -0.51, -0.43, 0.34, -0.01, 0.17, 0.02, -0.06, 0.30, 0.44, -0.28, -0.31, -0.17, 0.04, 0.39, -0.12, 0.12, 0.0 },
    .{ -0.06, -0.05, 0.06, 0.17, 0.15, 0.0, 0.11, -0.05, -0.16, 0.02, 0.11, 0.04, 0.12, 0.07, 0.02, -0.14, -0.14 },
    .{ 0.01, -0.03, 0.01, -0.01, 0.05, -0.03, 0.05, -0.03, -0.01, 0.0, -0.08, -0.04, 0.0, -0.02, -0.03, 0.0, -0.03 },
    .{ -0.01, 0.0, 0.01, 0.0, 0.01, 0.0, -0.01, -0.01, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{ 0.0, 0.0, 0.03, 0.01, 0.02, 0.01, 0.0, -0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{ -0.19, -0.02, 0.12, -0.10, 0.06, 0.0, -0.02, -0.08, -0.02, -0.07, 0.01, 0.03, 0.15, 0.06, -0.05, -0.03, -0.10 },
    .{ -0.18, 0.06, -0.55, -0.02, 0.09, -0.08, 0.0, 0.86, -0.18, -0.05, -0.07, 0.04, 0.14, -0.03, 0.37, -0.11, -0.12 },
    .{ 1.09, -0.14, -0.21, 0.52, 0.27, 0.0, 0.11, 0.17, 0.23, 0.35, -0.05, 0.02, -0.60, 0.02, 0.01, 0.27, 0.32 },
    .{ -0.34, -0.09, -1.22, 0.05, 0.15, -0.29, -0.17, 1.58, -0.06, -0.15, 0.00, 0.13, 0.28, -0.08, 0.62, -0.01, -0.04 },
    .{ -0.13, 0.07, -0.37, 0.05, 0.06, -0.11, -0.07, 0.46, 0.00, -0.04, 0.01, 0.07, 0.09, -0.05, 0.15, -0.01, 0.01 },
    .{ -0.06, 0.13, -0.07, 0.03, 0.02, -0.05, -0.05, 0.01, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{ -0.03, 0.08, -0.01, 0.04, 0.01, -0.02, -0.02, -0.04, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
};

const b = [12][17]f64{
    .{ 0.23, -0.20, -0.31, 0.16, -0.03, 0.02, 0.04, 0.18, 0.34, 0.45, 0.19, -0.25, -0.12, 0.18, 0.40, -0.09, 0.21 },
    .{ 0.02, -0.08, -0.06, -0.11, 0.15, -0.14, 0.01, 0.01, 0.04, -0.14, -0.05, 0.08, 0.08, -0.01, 0.01, 0.11, -0.12 },
    .{ 0.0, -0.02, -0.03, -0.05, -0.01, -0.07, -0.03, -0.01, 0.02, -0.01, 0.03, -0.10, 0.01, 0.05, -0.01, 0.04, 0.00 },
    .{ 0.0, -0.02, 0.01, 0.0, -0.01, 0.01, 0.0, -0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{ 0.01, 0.0, 0.0, 0.01, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{ -0.09, 0.07, 0.03, 0.06, 0.09, 0.01, 0.02, 0.0, -0.04, -0.02, -0.01, 0.01, -0.10, 0.0, -0.01, 0.02, 0.05 },
    .{ 0.15, -0.31, 0.13, 0.05, -0.09, -0.03, 0.06, -0.36, 0.08, 0.05, 0.06, -0.02, -0.05, 0.06, -0.20, 0.04, 0.07 },
    .{ 0.50, -0.08, -0.38, 0.36, 0.14, 0.04, 0.0, 0.25, 0.17, 0.27, -0.03, -0.03, -0.32, -0.10, 0.20, 0.10, 0.30 },
    .{ 0.0, -0.11, -0.22, 0.01, 0.02, -0.03, -0.01, 0.49, -0.03, -0.02, 0.01, 0.02, 0.04, -0.04, 0.16, -0.02, -0.01 },
    .{ 0.05, 0.03, 0.07, 0.02, -0.01, 0.03, 0.02, -0.04, -0.01, -0.01, 0.02, 0.03, 0.02, -0.04, -0.04, -0.01, 0.0 },
    .{ 0.03, -0.02, 0.04, -0.01, -0.03, 0.02, 0.01, 0.04, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
    .{ 0.04, -0.02, -0.04, 0.00, -0.01, 0.0, 0.01, 0.07, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 },
};
