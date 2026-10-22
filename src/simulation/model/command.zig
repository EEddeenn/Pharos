const std = @import("std");
const power = @import("simulation/model/power");

const max_elevation_mask_rad: f64 = std.math.pi / 2.0;

pub const Kind = enum(u32) {
    noise_floor_dbm_hz = 0,
    elevation_mask = 1,
    signal_power = 2,
};

pub const Action = union(Kind) {
    noise_floor_dbm_hz: f64,
    elevation_mask: f64,
    signal_power: power.SignalPower,
};

pub const Command = struct {
    apply_at_epoch: u64 = 0,
    action: Action,
};

pub fn check(c: Command) error{InvalidValue}!void {
    switch (c.action) {
        .noise_floor_dbm_hz => |v| if (!std.math.isFinite(v) or v < power.noise_floor_range[0] or v > power.noise_floor_range[1]) return error.InvalidValue,
        .elevation_mask => |v| if (!std.math.isFinite(v) or @abs(v) > max_elevation_mask_rad) return error.InvalidValue,
        .signal_power => |p| {
            if (p.target == .sat and !p.target.sat.valid()) return error.InvalidValue;
            if (p.level) |l| {
                if (!std.math.isFinite(l.value)) return error.InvalidValue;
                const lowest = l.cn0(power.noise_floor_range[1]);
                const highest = l.cn0(power.noise_floor_range[0]);
                if (highest < power.cn0_range[0] or lowest > power.cn0_range[1]) return error.InvalidValue;
            }
        },
    }
}
