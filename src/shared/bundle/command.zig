const std = @import("std");
const types = @import("../core.zig").types;

const dbw_to_dbm = 30.0;

pub const noise_floor_range: [2]f64 = .{ -250, 0 };
pub const cn0_range: [2]f64 = .{ -100, 100 };
pub const max_elevation_mask_rad: f64 = std.math.pi / 2.0;

pub const PowerUnit = enum(u32) {
    dbhz = 0,
    dbm = 1,
    dbw = 2,

    pub const words: std.EnumArray(PowerUnit, []const u8) = .init(.{ .dbhz = "dBHz", .dbm = "dBm", .dbw = "dBW" });
};

pub const PowerLevel = struct {
    unit: PowerUnit,
    value: f64,

    pub fn cn0(self: PowerLevel, noise_floor_dbm_hz: f64) f64 {
        return switch (self.unit) {
            .dbhz => self.value,
            .dbm => self.value - noise_floor_dbm_hz,
            .dbw => self.value - noise_floor_dbm_hz + dbw_to_dbm,
        };
    }
};

pub const Kind = enum(u32) {
    noise_floor_dbm_hz = 0,
    elevation_mask = 1,
    signal_power = 2,
};

pub const Target = union(enum) {
    whole: types.System,
    sat: types.SatId,

    pub fn system(self: Target) types.System {
        return switch (self) {
            .whole => |s| s,
            .sat => |s| s.system,
        };
    }
};

pub const Action = union(Kind) {
    noise_floor_dbm_hz: f64,
    elevation_mask: f64,
    signal_power: struct { target: Target, level: ?PowerLevel },
};

pub const Command = struct {
    apply_at_epoch: u64 = 0,
    action: Action,
};

pub fn check(c: Command) error{InvalidValue}!void {
    switch (c.action) {
        .noise_floor_dbm_hz => |v| if (!std.math.isFinite(v) or v < noise_floor_range[0] or v > noise_floor_range[1]) return error.InvalidValue,
        .elevation_mask => |v| if (!std.math.isFinite(v) or @abs(v) > max_elevation_mask_rad) return error.InvalidValue,
        .signal_power => |p| if (p.level) |l| {
            if (!std.math.isFinite(l.value)) return error.InvalidValue;
            const lowest = l.cn0(noise_floor_range[1]);
            const highest = l.cn0(noise_floor_range[0]);
            if (highest < cn0_range[0] or lowest > cn0_range[1]) return error.InvalidValue;
        },
    }
}

pub const PowerEntry = struct {
    at_epoch: u64,
    target: Target,
    level: ?PowerLevel,
};
