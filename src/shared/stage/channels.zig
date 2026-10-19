const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const bundle = @import("../bundle.zig");
const messages = @import("messages.zig");
const types = core.types;
const Epoch = core.time.Epoch;

pub const replan_epochs: u32 = 1000;

const hysteresis_rad: f64 = 0.5 * std.math.pi / 180.0;

pub const State = enum(u32) {
    held = 0,
    masked_out = 1,
    not_broadcast = 2,
    no_record = 3,
    below_mask = 4,
    outside_band = 5,
    no_frames = 6,
    declared_dead = 7,
};

pub const Sight = struct { air: []const gnss.air.Row, freq: ?types.FreqId, el_rad: f64 };

pub fn replanAt(epoch: Epoch, epochs: u64) Epoch {
    return .{ .ms = @min(epoch.ms / replan_epochs, (epochs - 1) / replan_epochs) * replan_epochs };
}

pub fn replanOnOrAfter(epoch: Epoch) Epoch {
    return .{ .ms = (epoch.ms + replan_epochs - 1) / replan_epochs * replan_epochs };
}

fn offAir(status: gnss.air.Status) ?State {
    return switch (status) {
        .on_air => null,
        .dead => .declared_dead,
        .not_allocated => .not_broadcast,
    };
}

pub fn keep(key: types.ChannelKey, sight: ?Sight, mask_rad: f64, snapshot: messages.Snapshot) State {
    const seen = sight orelse return .no_record;
    const set = messages.forSignal(snapshot, key.signal) orelse return .no_frames;
    if (offAir(seen.air[gnss.spec.slot(key.signal)].status)) |state| return state;
    if (seen.el_rad < mask_rad - hysteresis_rad) return .below_mask;
    if (!set.hasFrames(key.sat.prn())) return .no_frames;
    return .held;
}

pub const Rules = struct {
    allocation: *const gnss.allocation.Allocation,
    samples: bundle.scenario.Samples,

    pub fn admit(self: *const Rules, key: types.ChannelKey, sight: ?Sight, mask_rad: f64, snapshot: messages.Snapshot) messages.MissingData!State {
        if (!self.allocation.transmits(key.sat, key.signal)) return .not_broadcast;
        const seen = sight orelse return .no_record;
        if (offAir(seen.air[gnss.spec.slot(key.signal)].status)) |state| return state;
        if (seen.el_rad < mask_rad) return .below_mask;
        if (!self.samples.inBand(gnss.spec.get(key.signal).carrierHz(seen.freq))) return .outside_band;
        const set = messages.forSignal(snapshot, key.signal) orelse return .no_frames;
        try set.requireData(key.sat.prn());
        if (!set.hasFrames(key.sat.prn())) return .no_frames;
        return .held;
    }
};
