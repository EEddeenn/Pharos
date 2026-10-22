const std = @import("std");
const gnss_types = @import("domain/gnss_types");

pub const noise_floor_range: [2]f64 = .{ -250, 0 };
pub const cn0_range: [2]f64 = .{ -100, 100 };

const dbw_to_dbm = 30.0;

pub const Unit = enum(u32) {
    dbhz = 0,
    dbm = 1,
    dbw = 2,

    pub const words: std.EnumArray(Unit, []const u8) = .init(.{ .dbhz = "dBHz", .dbm = "dBm", .dbw = "dBW" });
};

pub const Level = struct {
    unit: Unit,
    value: f64,

    pub fn cn0(self: Level, noise_floor_dbm_hz: f64) f64 {
        return switch (self.unit) {
            .dbhz => self.value,
            .dbm => self.value - noise_floor_dbm_hz,
            .dbw => self.value - noise_floor_dbm_hz + dbw_to_dbm,
        };
    }
};

pub const Target = union(enum) {
    whole: gnss_types.System,
    sat: gnss_types.SatId,

    pub fn system(self: Target) gnss_types.System {
        return switch (self) {
            .whole => |s| s,
            .sat => |s| s.system,
        };
    }
};

pub const SignalPower = struct { target: Target, level: ?Level };
pub const Action = union(enum) { noise_floor_dbm_hz: f64, signal_power: SignalPower };
pub const Entry = struct { at_epoch: u64, target: Target, level: ?Level };

pub const Config = struct {
    noise_floor_dbm_hz: f64,
    init_cn0_dbhz: f64,
    elevation_fade: bool,
    schedule: []const Entry,
};

pub fn clampCn0(cn0_dbhz: f64) f64 {
    return std.math.clamp(cn0_dbhz, cn0_range[0], cn0_range[1]);
}
