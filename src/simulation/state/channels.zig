const std = @import("std");
const air = @import("domain/navigation/air");
const signal_catalog = @import("domain/signals/catalog");
const configuration = @import("simulation/model/config");
const gnss_types = @import("domain/gnss_types");

const Payload = @import("domain/signals/payload").Payload;
const Log = @import("simulation/state/commands").Log;
const Epoch = @import("domain/time/gps").Epoch;

pub const replan_epochs: u32 = 1000;

const hysteresis_rad: f64 = 0.5 * std.math.pi / 180.0;

pub const State = enum(u32) {
    held = 0,
    masked_out = 1,
    not_broadcast = 2,
    no_record = 3,
    below_mask = 4,
    outside_band = 5,
    not_carried = 6,
    declared_dead = 7,
};

pub const Sight = struct { air: []const air.Row, freq: ?gnss_types.FreqId, el_rad: f64 };

pub const Rules = struct {
    payload: *const Payload,
    samples: configuration.Samples,

    pub fn admit(self: *const Rules, key: gnss_types.ChannelKey, sight: ?Sight, mask_rad: f64) State {
        if (!self.payload.transmits(key.sat, key.signal)) return .not_broadcast;
        const seen = sight orelse return .no_record;
        if (offAir(seen.air[signal_catalog.slot(key.signal)].status)) |state| return state;
        if (seen.el_rad < mask_rad) return .below_mask;
        if (!self.samples.inBand(signal_catalog.get(key.signal).carrierHz(seen.freq))) return .outside_band;
        return .held;
    }
};

pub const Held = struct { key: gnss_types.ChannelKey, track: usize, freq: ?gnss_types.FreqId };

pub const Change = struct {
    track: usize,
    signal: gnss_types.Signal,
    action: union(enum) { state: State, enter: ?gnss_types.FreqId, readmit: ?gnss_types.FreqId },

    pub fn state(self: Change) State {
        return switch (self.action) {
            .state => |value| value,
            .enter, .readmit => .held,
        };
    }
};

pub const Selection = struct {
    rules: Rules,
    signals: std.EnumSet(gnss_types.Signal),
    mask_rad: f64,
    log: *const Log,
    sats: []const gnss_types.SatId,
    states: []std.EnumArray(gnss_types.Signal, State),
    held: std.ArrayList(Held),
    changes: std.ArrayList(Change),

    pub fn init(gpa: std.mem.Allocator, rules: Rules, signals: std.EnumSet(gnss_types.Signal), mask_rad: f64, log: *const Log, sats: []const gnss_types.SatId) error{OutOfMemory}!Selection {
        const states = try gpa.alloc(std.EnumArray(gnss_types.Signal, State), sats.len);
        errdefer gpa.free(states);
        @memset(states, .initFill(.no_record));
        var count: usize = 0;
        var it = signals.iterator();
        while (it.next()) |signal| {
            for (sats) |sat| {
                if (sat.system == signal.system()) count += 1;
            }
        }
        var held = try std.ArrayList(Held).initCapacity(gpa, count);
        errdefer held.deinit(gpa);
        const changes = try std.ArrayList(Change).initCapacity(gpa, count);
        return .{ .rules = rules, .signals = signals, .mask_rad = mask_rad, .log = log, .sats = sats, .states = states, .held = held, .changes = changes };
    }

    pub fn deinit(self: *Selection, gpa: std.mem.Allocator) void {
        self.changes.deinit(gpa);
        self.held.deinit(gpa);
        gpa.free(self.states);
    }

    pub fn reset(self: *Selection) void {
        @memset(self.states, .initFill(.no_record));
        self.held.clearRetainingCapacity();
        self.changes.clearRetainingCapacity();
    }

    pub fn replan(self: *Selection, sights: []const ?Sight, r: Epoch) void {
        self.changes.clearRetainingCapacity();
        const mask_rad = self.log.maskAt(self.mask_rad, r);
        for (self.held.items) |h| {
            const state = keep(h.key, sights[h.track], mask_rad);
            if (state != .held) {
                self.record(h.track, h.key.signal, .{ .state = state });
            } else if (!std.meta.eql(h.freq, sights[h.track].?.freq)) {
                const admitted = self.rules.admit(h.key, sights[h.track], mask_rad);
                self.record(h.track, h.key.signal, if (admitted == .held) .{ .readmit = sights[h.track].?.freq } else .{ .state = admitted });
            }
        }
        var it = self.signals.iterator();
        while (it.next()) |signal| {
            for (self.sats, 0..) |sat, track| {
                if (sat.system != signal.system()) continue;
                const key: gnss_types.ChannelKey = .{ .sat = sat, .signal = signal };
                const previous = self.states[track].get(signal);
                if (previous == .held) continue;
                const state = self.rules.admit(key, sights[track], mask_rad);
                if (state != previous) self.record(track, signal, if (state == .held) .{ .enter = sights[track].?.freq } else .{ .state = state });
            }
        }
        for (self.changes.items) |c| self.redo(c);
    }

    pub fn restore(self: *Selection, states: []const std.EnumArray(gnss_types.Signal, State), held: []const Held) void {
        @memcpy(self.states, states);
        self.held.clearRetainingCapacity();
        self.held.appendSliceAssumeCapacity(held);
    }

    pub fn redo(self: *Selection, c: Change) void {
        const was = self.states[c.track].get(c.signal);
        self.states[c.track].set(c.signal, c.state());
        const key: gnss_types.ChannelKey = .{ .sat = self.sats[c.track], .signal = c.signal };
        switch (c.action) {
            .state => if (was == .held) self.remove(key),
            .enter, .readmit => |freq| {
                if (was == .held) self.remove(key);
                self.held.appendAssumeCapacity(.{ .key = key, .track = c.track, .freq = freq });
            },
        }
    }

    fn record(self: *Selection, track: usize, signal: gnss_types.Signal, action: @FieldType(Change, "action")) void {
        self.changes.appendAssumeCapacity(.{ .track = track, .signal = signal, .action = action });
    }

    fn remove(self: *Selection, key: gnss_types.ChannelKey) void {
        for (self.held.items, 0..) |h, j| if (h.key == key) {
            _ = self.held.orderedRemove(j);
            return;
        };
    }
};

pub fn replanAt(epoch: Epoch, epochs: u64) Epoch {
    return .{ .ms = @min(epoch.ms / replan_epochs, (epochs - 1) / replan_epochs) * replan_epochs };
}

pub fn replanOnOrAfter(epoch: Epoch) Epoch {
    return .{ .ms = (epoch.ms + replan_epochs - 1) / replan_epochs * replan_epochs };
}

fn keep(key: gnss_types.ChannelKey, sight: ?Sight, mask_rad: f64) State {
    const seen = sight orelse return .no_record;
    if (offAir(seen.air[signal_catalog.slot(key.signal)].status)) |state| return state;
    if (seen.el_rad < mask_rad - hysteresis_rad) return .below_mask;
    return .held;
}

fn offAir(status: air.Status) ?State {
    return switch (status) {
        .on_air => null,
        .dead => .declared_dead,
        .not_carried => .not_carried,
        .not_allocated => .not_broadcast,
    };
}
