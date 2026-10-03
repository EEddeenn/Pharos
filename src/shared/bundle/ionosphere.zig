const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const iono = core.iono;
const System = core.types.System;

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
    klobuchar: iono.klobuchar.Model,
    bds_klobuchar: iono.klobuchar.Model,
    nequick: ?iono.nequick.Coefficients,
    bdgim: ?[9]f64,

    pub fn misfit(self: Broadcast) ?[:0]const u8 {
        return gnss.plausible.broadcastIono(.{ .klobuchar = self.klobuchar, .bds_klobuchar = self.bds_klobuchar, .nequick = self.nequick, .bdgim = self.bdgim });
    }
};

pub const Applied = struct {
    model: Model,
    source: Source,

    fn valid(self: Applied, broadcast: Broadcast) bool {
        return switch (self.model) {
            .none => self.source == .none,
            .klobuchar => self.source == .scenario or self.source == .navigation or
                (self.source == .built_in and std.meta.eql(broadcast.klobuchar, iono.klobuchar.Model.default_broadcast)),
            .bds_klobuchar => self.source == .scenario or self.source == .navigation,
            .nequick => broadcast.nequick != null and (self.source == .scenario or self.source == .navigation),
            .bdgim => broadcast.bdgim != null and (self.source == .scenario or self.source == .navigation),
        };
    }
};

pub const Resolved = struct {
    requested: Selection,
    systems: std.EnumArray(System, Applied),
    broadcast: Broadcast,

    pub fn valid(self: Resolved) bool {
        if (self.broadcast.misfit() != null) return false;
        for (System.all) |system| {
            const applied = self.systems.get(system);
            if (!applied.valid(self.broadcast)) return false;
            const selected = applied.model;
            if (self.requested.model()) |model| {
                if (selected != model or !std.meta.eql(applied, self.systems.get(.gps))) return false;
            } else {
                if (applied.source == .scenario) return false;
                if (selected == .none) continue;
                const fits = switch (system) {
                    .gps, .glo => selected == .klobuchar,
                    .gal => selected == .nequick,
                    .bds => if (self.broadcast.bdgim != null) selected == .bdgim else selected == .bds_klobuchar,
                };
                if (!fits) return false;
            }
        }
        return true;
    }
};

pub const Configuration = union(enum) {
    inactive,
    ready: Resolved,
};
