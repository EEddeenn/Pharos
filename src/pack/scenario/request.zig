const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const scenario = shared.bundle.scenario;
const System = core.types.System;
const Signal = core.types.Signal;
const SatSet = core.types.SatSet;
const GpsTime = core.time.GpsTime;

pub const Request = struct {
    name: []const u8,
    start: GpsTime,
    trajectory_file: []const u8,
    duration_ms: ?u64,
    nav_files: []const scenario.NavFile,
    antenna: ?[]const u8,
    precise: ?scenario.Precise,
    has: ?scenario.Has,
    ppp_b2b: ?scenario.PppB2b,
    ionosphere: Ionosphere,
    messages: scenario.Messages = .{},
    signals: std.EnumSet(Signal),
    elevation_mask_rad: f64,
    mask_out: std.EnumArray(System, SatSet),
    samples: ?scenario.Samples,
    observation: ?scenario.Observation,
    position: ?scenario.Position,
    power: scenario.Power,

    pub const carries = scenario.Scenario.carries;
    pub const enabledSystems = scenario.Scenario.enabledSystems;
    pub const listedSignalOf = scenario.Scenario.listedSignalOf;
    pub const transmitsListed = scenario.Scenario.transmitsListed;
};

pub const Ionosphere = union(scenario.IonoSelection) {
    auto,
    klobuchar: ?core.iono.klobuchar.Model,
    bds_klobuchar: ?core.iono.klobuchar.Model,
    nequick: ?core.iono.nequick.Coefficients,
    bdgim: ?[9]f64,
    none,

    pub fn model(self: Ionosphere) scenario.IonoSelection {
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
            .klobuchar, .bds_klobuchar => |c| gnss.plausible.klobuchar(c orelse return null),
            .nequick => |c| gnss.plausible.nequick(c orelse return null),
            .bdgim => |c| gnss.plausible.bdgim(c orelse return null),
            .auto, .none => null,
        };
    }
};
