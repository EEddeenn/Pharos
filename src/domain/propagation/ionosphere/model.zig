const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const coordinates = @import("domain/earth/coordinates");
const klobuchar = @import("domain/propagation/ionosphere/klobuchar");
const nequick = @import("domain/propagation/ionosphere/nequick");
const bdgim = @import("domain/propagation/ionosphere/bdgim");

const System = gnss_types.System;
const GpsTime = time.GpsTime;

pub const Model = union(enum) {
    none,
    klobuchar: klobuchar.Model,
    bds_klobuchar: klobuchar.Model,
    nequick: nequick.Model,
    bdgim: bdgim.Model,

    pub fn verticalL1(self: *const Model, t: GpsTime, point: coordinates.Lla) f64 {
        const ground: coordinates.Lla = .{ .lat_rad = point.lat_rad, .lon_rad = point.lon_rad, .height_m = 0 };
        const top = coordinates.llaToEcef(.{ .lat_rad = point.lat_rad, .lon_rad = point.lon_rad, .height_m = vertical_top_m });
        var preparer: Preparer = .{};
        const prepared = preparer.modelAt(self, t, ground);
        return prepared.delayL1(top, std.math.pi / 2.0, 0);
    }
};

pub const Models = struct {
    values: std.EnumArray(System, Model) = .initFill(.none),

    pub fn get(self: *const Models, system: System) *const Model {
        return self.values.getPtrConst(system);
    }
};

pub const Prepared = union(enum) {
    none,
    klobuchar: klobuchar.Prepared,
    bds_klobuchar: klobuchar.BdsPrepared,
    nequick: nequick.Prepared,
    bdgim: bdgim.Prepared,

    pub fn delayL1(self: *const Prepared, sat: coordinates.Ecef, el_rad: f64, az_rad: f64) f64 {
        return switch (self.*) {
            .none => 0,
            inline else => |*model| model.delayL1(sat, el_rad, az_rad),
        };
    }
};

pub const PreparedModels = struct {
    values: std.EnumArray(System, Prepared),

    pub fn get(self: *const PreparedModels, system: System) *const Prepared {
        return self.values.getPtrConst(system);
    }
};

pub const Preparer = struct {
    bdgim_prediction: bdgim.PredictionCache = .{},

    pub fn at(self: *Preparer, models: *const Models, t: GpsTime, rx: coordinates.Lla, out: *PreparedModels) void {
        for (System.all) |system| out.values.set(system, self.modelAt(models.get(system), t, rx));
    }

    fn modelAt(self: *Preparer, model: *const Model, t: GpsTime, rx: coordinates.Lla) Prepared {
        return switch (model.*) {
            .none => .none,
            .klobuchar => |value| .{ .klobuchar = klobuchar.Prepared.at(value, t, rx) },
            .bds_klobuchar => |value| .{ .bds_klobuchar = klobuchar.BdsPrepared.at(value, t, rx) },
            .nequick => |value| .{ .nequick = nequick.Prepared.at(value, t, rx) },
            .bdgim => |value| .{ .bdgim = bdgim.Prepared.at(value, t, rx, &self.bdgim_prediction) },
        };
    }
};

const vertical_top_m: f64 = 20_000e3;

pub const SuppliedCoefficients = struct {
    klobuchar: ?klobuchar.Model = null,
    bds_klobuchar: ?klobuchar.Model = null,
    nequick: ?nequick.Coefficients = null,
    bdgim: ?[9]f64 = null,
};
