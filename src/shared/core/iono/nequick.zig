const std = @import("std");
const constants = @import("../constants.zig");
const coord = @import("../coord.zig");
const GpsTime = @import("../time.zig").GpsTime;
const data = @import("nequick/data/manifest.zig");
const modip = @import("nequick/modip.zig");
const ccir = @import("nequick/ccir.zig");
const profile = @import("nequick/profile.zig");
const ray = @import("nequick/ray.zig");

const Point = ray.Point;
const Error = ray.Error;

const default_az: f64 = 63.7;
const max_az: f64 = 400.0;
const tec_delay_m_hz2: f64 = 40.3e16;
const m_per_km: f64 = 1e3;
const electrons_m2_per_tecu: f64 = 1e16;

pub const Coefficients = struct {
    ai0: f64,
    ai1: f64,
    ai2: f64,

    pub const zero: Coefficients = .{ .ai0 = 0, .ai1 = 0, .ai2 = 0 };

    pub fn fromArray(a: [3]f64) Coefficients {
        return .{ .ai0 = a[0], .ai1 = a[1], .ai2 = a[2] };
    }

    pub fn az(self: Coefficients, modip_deg: f64) f64 {
        if (self.ai0 == 0 and self.ai1 == 0 and self.ai2 == 0) return default_az;
        const a = self.ai0 + (self.ai1 + self.ai2 * modip_deg) * modip_deg;
        return std.math.clamp(a, 0.0, max_az);
    }
};

fn sunspotNumber(az: f64) f64 {
    return @sqrt(167273.0 + (az - default_az) * 1123.6) - 408.99;
}

fn delayMetres(stec_tecu: f64, carrier_hz: f64) f64 {
    return tec_delay_m_hz2 * stec_tecu / (carrier_hz * carrier_hz);
}

pub const Data = struct {
    grid: modip.Grid,
    months: [12]ccir.Month,

    pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Data {
        const d = try gpa.create(Data);
        d.grid.parse(data.modip.bytes) catch unreachable;
        for (&d.months, data.ccir) |*month, f| month.parse(f.bytes) catch unreachable;
        return d;
    }

    pub fn destroy(self: *const Data, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }
};

pub const Model = struct {
    data: *const Data,
    coefficients: Coefficients,
};

pub const Prepared = struct {
    grid: *const modip.Grid,
    receiver: Point,
    az: f64,
    azr: f64,
    month: u8,
    ut_hours: f64,
    sun: profile.Sun,
    epoch: ccir.Epoch,

    pub fn at(model: Model, t: GpsTime, rx: coord.Lla) Prepared {
        const utc = t.toUtc(.table);
        const ut_hours = @min(@as(f64, @floatFromInt(utc.hour)) + @as(f64, @floatFromInt(utc.minute)) / 60.0 + utc.second / 3600.0, 24.0);
        const receiver = pointOf(rx);
        const az = model.coefficients.az(model.data.grid.at(receiver.lat_deg, receiver.lon_deg));
        const azr = sunspotNumber(az);
        return .{
            .grid = &model.data.grid,
            .receiver = receiver,
            .az = az,
            .azr = azr,
            .month = utc.month,
            .ut_hours = ut_hours,
            .sun = profile.Sun.at(utc.month, ut_hours),
            .epoch = ccir.Epoch.compute(&model.data.months[utc.month - 1], azr, ut_hours),
        };
    }

    pub fn delayL1(self: *const Prepared, sat: coord.Ecef, _: f64, _: f64) f64 {
        const tec = self.stec(pointOf(coord.ecefToLla(sat))) catch return 0;
        return delayMetres(tec, constants.iono_reference_hz);
    }

    fn stec(self: *const Prepared, satellite: Point) Error!f64 {
        const path = try ray.Ray.between(self.receiver, satellite);
        const ctx: profile.Context = .{
            .az = self.az,
            .azr = self.azr,
            .month = self.month,
            .ut_hours = self.ut_hours,
            .sun = self.sun,
            .epoch = &self.epoch,
            .grid = self.grid,
        };
        const electrons_per_m2_km = if (path.vertical) blk: {
            const layers = profile.Layers.at(&ctx, self.receiver.lat_deg, self.receiver.lon_deg);
            break :blk ray.integrate(&path, &layers, densityAtHeight);
        } else blk: {
            const slant: Slant = .{ .ctx = &ctx, .ray = &path };
            break :blk ray.integrate(&path, &slant, densityAlongRay);
        };
        return electrons_per_m2_km * m_per_km / electrons_m2_per_tecu;
    }

    const Slant = struct { ctx: *const profile.Context, ray: *const ray.Ray };

    fn densityAtHeight(layers: *const profile.Layers, h_km: f64) f64 {
        return layers.density(h_km);
    }

    fn densityAlongRay(slant: *const Slant, s_km: f64) f64 {
        const p = slant.ray.pointAt(s_km);
        const layers = profile.Layers.at(slant.ctx, p.lat_deg, p.lon_deg);
        return layers.density(p.h_km);
    }
};

fn pointOf(p: coord.Lla) Point {
    return .{ .lat_deg = p.latDeg(), .lon_deg = p.lonDeg(), .h_km = p.height_m / m_per_km };
}
