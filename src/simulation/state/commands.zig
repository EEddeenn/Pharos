const std = @import("std");
const command = @import("simulation/model/command");
const power_model = @import("simulation/model/power");

const Power = @import("simulation/state/power").Power;
const Epoch = @import("domain/time/gps").Epoch;

const Mask = struct { apply_at_epoch: u64, rad: f64 };
const PowerCommand = struct { apply_at_epoch: u64, action: power_model.Action };

pub const Log = struct {
    power: std.ArrayList(PowerCommand) = .empty,
    masks: std.ArrayList(Mask) = .empty,

    pub const Capacity = struct {
        power: usize = 0,
        masks: usize = 0,

        pub fn include(self: *Capacity, c: command.Command) void {
            switch (c.action) {
                .elevation_mask => self.masks += 1,
                .noise_floor_dbm_hz, .signal_power => self.power += 1,
            }
        }
    };

    pub fn deinit(self: *Log, gpa: std.mem.Allocator) void {
        self.masks.deinit(gpa);
        self.power.deinit(gpa);
    }

    pub fn add(self: *Log, gpa: std.mem.Allocator, c: command.Command) error{OutOfMemory}!void {
        var capacity: Capacity = .{};
        capacity.include(c);
        try self.reserve(gpa, capacity);
        self.addAssumeCapacity(c);
    }

    pub fn reserve(self: *Log, gpa: std.mem.Allocator, capacity: Capacity) error{OutOfMemory}!void {
        try self.power.ensureUnusedCapacity(gpa, capacity.power);
        try self.masks.ensureUnusedCapacity(gpa, capacity.masks);
    }

    pub fn addAssumeCapacity(self: *Log, c: command.Command) void {
        switch (c.action) {
            .elevation_mask => |rad| self.masks.insertAssumeCapacity(after(Mask, self.masks.items, c.apply_at_epoch), .{ .apply_at_epoch = c.apply_at_epoch, .rad = rad }),
            inline .noise_floor_dbm_hz, .signal_power => |value, tag| self.power.insertAssumeCapacity(after(PowerCommand, self.power.items, c.apply_at_epoch), .{ .apply_at_epoch = c.apply_at_epoch, .action = @unionInit(power_model.Action, @tagName(tag), value) }),
        }
    }

    pub fn maskAt(self: *const Log, scenario_mask_rad: f64, replan: Epoch) f64 {
        const n = after(Mask, self.masks.items, replan.ms);
        return if (n == 0) scenario_mask_rad else self.masks.items[n - 1].rad;
    }

    fn powerTo(self: *const Log, power: *Power, next: *usize, epoch: Epoch) void {
        while (next.* < self.power.items.len and self.power.items[next.*].apply_at_epoch <= epoch.ms) : (next.* += 1) {
            const c = self.power.items[next.*];
            power.advanceTo(.{ .ms = c.apply_at_epoch });
            power.apply(c.action);
        }
        power.advanceTo(epoch);
    }
};

pub const PowerPlayback = struct {
    state: Power,
    next_command: usize = 0,
    epoch: ?Epoch = null,

    pub fn init(config: power_model.Config) PowerPlayback {
        return .{ .state = .init(config) };
    }

    pub fn reset(self: *PowerPlayback) void {
        self.state.reset();
        self.next_command = 0;
        self.epoch = null;
    }

    pub fn advance(self: *PowerPlayback, log: *const Log, epoch: Epoch) void {
        if (self.epoch == null or epoch.ms < self.epoch.?.ms) self.reset();
        log.powerTo(&self.state, &self.next_command, epoch);
        self.epoch = epoch;
    }

    pub fn invalidate(self: *PowerPlayback, from: Epoch) void {
        if (self.epoch) |at| {
            if (from.ms <= at.ms) self.epoch = null;
        }
    }
};

fn after(comptime T: type, items: []const T, epoch: u64) usize {
    return std.sort.upperBound(T, items, epoch, struct {
        fn order(at: u64, item: T) std.math.Order {
            return std.math.order(at, item.apply_at_epoch);
        }
    }.order);
}
