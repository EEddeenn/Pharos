const std = @import("std");
const core = @import("../core.zig");
const types = core.types;
const Epoch = core.time.Epoch;
const bundle = @import("../bundle.zig");
const command = bundle.command;
const model = bundle.scenario;

const SatPower = union(enum) { default, scheduled: f64, commanded: f64 };

const Setter = enum { schedule, command };

const fade_depth_db: f64 = 25.0;

pub const Power = struct {
    config: model.Power,
    default_cn0_dbhz: f64,
    noise_floor_dbm_hz: f64,
    next_entry: usize,
    state: std.EnumArray(types.System, [64]SatPower),

    pub fn init(p: model.Power) Power {
        var power: Power = .{ .config = p, .default_cn0_dbhz = undefined, .noise_floor_dbm_hz = undefined, .next_entry = undefined, .state = undefined };
        power.reset();
        return power;
    }

    pub fn reset(self: *Power) void {
        self.default_cn0_dbhz = self.config.init_cn0_dbhz;
        self.noise_floor_dbm_hz = self.config.noise_floor_dbm_hz;
        self.next_entry = 0;
        self.state = .initFill(@splat(.default));
    }

    pub fn advanceTo(self: *Power, epoch: Epoch) void {
        while (self.next_entry < self.config.schedule.len and self.config.schedule[self.next_entry].at_epoch <= epoch.ms) : (self.next_entry += 1) {
            const e = self.config.schedule[self.next_entry];
            self.setPower(e.target, e.level, .schedule);
        }
    }

    pub fn nextAfter(self: *const Power, epoch: Epoch) ?Epoch {
        for (self.config.schedule[self.next_entry..]) |e| if (e.at_epoch > epoch.ms) return .{ .ms = e.at_epoch };
        return null;
    }

    pub fn apply(self: *Power, action: command.Action) void {
        switch (action) {
            .noise_floor_dbm_hz => |v| self.setNoiseFloor(v),
            .signal_power => |p| self.setPower(p.target, p.level, .command),
            .elevation_mask => {},
        }
    }

    fn setNoiseFloor(self: *Power, floor: f64) void {
        const delta = floor - self.noise_floor_dbm_hz;
        self.noise_floor_dbm_hz = floor;
        self.default_cn0_dbhz -= delta;
        for (&self.state.values) |*system| for (system) |*e| switch (e.*) {
            .scheduled, .commanded => |*v| v.* -= delta,
            .default => {},
        };
    }

    fn setPower(self: *Power, target: command.Target, level: ?command.PowerLevel, by: Setter) void {
        const value: SatPower = if (level) |l| switch (by) {
            .schedule => .{ .scheduled = clamped(l.cn0(self.noise_floor_dbm_hz)) },
            .command => .{ .commanded = clamped(l.cn0(self.noise_floor_dbm_hz)) },
        } else .default;
        switch (target) {
            .whole => |system| @memset(self.state.getPtr(system), value),
            .sat => |sat| self.state.getPtr(sat.system)[sat.index] = value,
        }
    }

    pub fn cn0(self: *const Power, sat: types.SatId, el_rad: f64) f64 {
        return switch (self.state.getPtrConst(sat.system)[sat.index]) {
            .scheduled, .commanded => |v| v,
            .default => self.default_cn0_dbhz - if (self.config.elevation_fade) fadeDb(el_rad) else 0,
        };
    }

    pub fn commanded(self: *const Power, sat: types.SatId) bool {
        return self.state.getPtrConst(sat.system)[sat.index] == .commanded;
    }
};

fn clamped(cn0_dbhz: f64) f64 {
    return std.math.clamp(cn0_dbhz, command.cn0_range[0], command.cn0_range[1]);
}

fn fadeDb(el_rad: f64) f64 {
    return (1.0 - @sqrt(@max(@sin(el_rad), 0.0))) * fade_depth_db;
}
