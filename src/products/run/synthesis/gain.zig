const std = @import("std");

const Epoch = @import("domain/time/gps").Epoch;

pub const evaluation_epochs: u32 = 100;

const clip_rate_high: f64 = 0.01;
const gain_down: f64 = 0.95;
const clip_rate_low: f64 = 0.001;
const gain_up: f64 = 1.02;

pub const Adjustment = struct { epoch: Epoch, gain: f64, clip_rate: f64, reduced: bool };

const Agc = struct {
    gain: f64 = 1.0,
    clipped: u64 = 0,
    components: u64 = 0,

    fn account(self: *Agc, epoch: Epoch, clipped: u64, components: u64) ?Adjustment {
        self.clipped += clipped;
        self.components += components;
        if (epoch.ms % evaluation_epochs != 0) return null;
        const rate = @as(f64, @floatFromInt(self.clipped)) / @as(f64, @floatFromInt(self.components));
        self.clipped = 0;
        self.components = 0;
        if (rate > clip_rate_high) {
            self.gain *= gain_down;
            return .{ .epoch = epoch, .gain = self.gain, .clip_rate = rate, .reduced = true };
        }
        if (rate < clip_rate_low and self.gain < 1.0) {
            self.gain = @min(self.gain * gain_up, 1.0);
            return .{ .epoch = epoch, .gain = self.gain, .clip_rate = rate, .reduced = false };
        }
        return null;
    }
};

pub const Mode = enum(u32) { adaptive = 0, constant = 1 };

pub const Db = struct {
    db: f64,

    pub const min: Db = .{ .db = -60 };
    pub const max: Db = .{ .db = 60 };

    pub fn fromValue(db: f64) ?Db {
        return if (db >= min.db and db <= max.db) .{ .db = db } else null;
    }

    fn linear(self: Db) Linear {
        return .{ .factor = @floatCast(std.math.pow(f64, 10.0, self.db / 20.0)) };
    }
};

pub const Linear = struct { factor: f32 };
pub const Setting = union(Mode) { adaptive, constant: Db };
pub const Status = union(Mode) { adaptive: f64, constant: Db };

pub const Gain = union(Mode) {
    adaptive: Agc,
    constant: struct { level: Db, linear: Linear },

    pub fn of(setting: Setting) Gain {
        return switch (setting) {
            .adaptive => .{ .adaptive = .{} },
            .constant => |level| .{ .constant = .{ .level = level, .linear = level.linear() } },
        };
    }

    pub fn status(self: Gain) Status {
        return switch (self) {
            .adaptive => |agc| .{ .adaptive = agc.gain },
            .constant => |value| .{ .constant = value.level },
        };
    }

    pub fn linear(self: Gain) Linear {
        return switch (self) {
            .adaptive => |agc| .{ .factor = @floatCast(agc.gain) },
            .constant => |constant| constant.linear,
        };
    }

    pub fn account(self: *Gain, epoch: Epoch, clipped: u64, components: u64) ?Adjustment {
        return switch (self.*) {
            .adaptive => |*agc| agc.account(epoch, clipped, components),
            .constant => null,
        };
    }
};

pub fn epochsToEvaluation(first: Epoch) u64 {
    return evaluation_epochs - first.ms % evaluation_epochs;
}
