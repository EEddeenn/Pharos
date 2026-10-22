const std = @import("std");
const nequick = @import("domain/propagation/ionosphere/nequick");
const ionosphere_klobuchar = @import("domain/propagation/ionosphere/klobuchar");
const System = @import("domain/gnss_types").System;

pub const Selection = enum {
    auto,
    klobuchar,
    bds_klobuchar,
    nequick,
    bdgim,
    none,

    pub const words: std.EnumArray(Selection, []const u8) = .init(.{ .auto = "auto", .klobuchar = "klobuchar", .bds_klobuchar = "bdsKlobuchar", .nequick = "nequick", .bdgim = "bdgim", .none = "none" });

    pub fn name(self: Selection) []const u8 {
        return words.get(self);
    }

    pub fn model(self: Selection) ?Model {
        return switch (self) {
            .auto => null,
            inline else => |tag| @field(Model, @tagName(tag)),
        };
    }
};

pub const Model = enum {
    klobuchar,
    bds_klobuchar,
    nequick,
    bdgim,
    none,

    pub const words: std.EnumArray(Model, []const u8) = .init(.{ .klobuchar = "klobuchar", .bds_klobuchar = "bdsKlobuchar", .nequick = "nequick", .bdgim = "bdgim", .none = "none" });

    pub fn name(self: Model) []const u8 {
        return words.get(self);
    }

    pub fn parameterCount(self: Model) usize {
        return switch (self) {
            .klobuchar, .bds_klobuchar => 8,
            .nequick => 3,
            .bdgim => 9,
            .none => 0,
        };
    }
};

pub const Source = enum { scenario, navigation, built_in, none };

pub const Broadcast = struct {
    klobuchar: ionosphere_klobuchar.Model,
    bds_klobuchar: ionosphere_klobuchar.Model,
    nequick: ?nequick.Coefficients,
    bdgim: ?[9]f64,
};

pub const Applied = struct {
    model: Model,
    source: Source,
};

pub const Resolved = struct {
    requested: Selection,
    systems: std.EnumArray(System, Applied),
    broadcast: Broadcast,
};

pub const Configuration = union(enum) {
    inactive,
    ready: Resolved,
};
