const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const ionosphere_klobuchar = @import("domain/propagation/ionosphere/klobuchar");
const names = @import("phb/model/names");
const clock_reference = @import("domain/navigation/clock_reference");
const publications = @import("simulation/model/publications");
const nequick = @import("domain/propagation/ionosphere/nequick");
const ionosphere_config = @import("simulation/model/ionosphere");
const navigation = @import("products/pack/input/admission/navigation");
const configuration = @import("simulation/model/config");
const System = gnss_types.System;
const Signal = gnss_types.Signal;
const SatSet = gnss_types.SatSet;
const GpsTime = @import("domain/time/gps").GpsTime;

/// A normalized request accepted by readRequest; its storage belongs to the caller's arena.
pub const Request = struct {
    name: []const u8,
    start: GpsTime,
    trajectory_file: []const u8,
    duration_ms: ?u64,
    nav_files: []const names.NavFile,
    antenna: ?[]const u8,
    precise: ?Precise,
    has: ?configuration.Has,
    ppp_b2b: ?configuration.PppB2b,
    ionosphere: Ionosphere,
    messages: publications.Publications = .{},
    signals: std.EnumSet(Signal),
    elevation_mask_rad: f64,
    mask_out: std.EnumArray(System, SatSet),
    samples: ?configuration.Samples,
    observation: ?configuration.Observation,
    position: ?configuration.Position,
    power: configuration.Power,
};

pub const Precise = struct {
    orbit: []const []const u8,
    clock: []const []const u8,
    clock_reference: clock_reference.ClockReferences,
};

pub const Ionosphere = union(ionosphere_config.Selection) {
    auto,
    klobuchar: ?ionosphere_klobuchar.Model,
    bds_klobuchar: ?ionosphere_klobuchar.Model,
    nequick: ?nequick.Coefficients,
    bdgim: ?[9]f64,
    none,

    pub fn model(self: Ionosphere) ionosphere_config.Selection {
        return self;
    }

    pub fn given(self: Ionosphere) bool {
        return switch (self) {
            .auto, .none => false,
            inline else => |c| c != null,
        };
    }

    pub fn misfit(self: Ionosphere) ?[:0]const u8 {
        return switch (self) {
            .klobuchar, .bds_klobuchar => |c| navigation.klobuchar(c orelse return null),
            .nequick => |c| navigation.nequick(c orelse return null),
            .bdgim => |c| navigation.bdgim(c orelse return null),
            .auto, .none => null,
        };
    }
};
