const std = @import("std");
const command = @import("shared").bundle.command;
const Epoch = @import("shared").core.time.Epoch;
const Log = @import("shared").stage.commands.Log;

pub const capacity: usize = 256;

pub const Command = command.Command;

pub const SubmitError = error{ EpochPassed, InvalidValue, TooManyPending };

pub const Applied = struct { epoch: Epoch, command: Command };

pub const Queue = struct {
    items: [capacity]Command = undefined,
    len: usize = 0,
    taken: u64 = 0,

    pub fn submit(self: *Queue, c: Command, next_epoch: Epoch) SubmitError!void {
        try command.check(c);
        if (c.apply_at_epoch != 0 and c.apply_at_epoch < next_epoch.ms) return error.EpochPassed;
        if (self.len == capacity) return error.TooManyPending;
        var bound = c;
        if (bound.apply_at_epoch == 0) bound.apply_at_epoch = next_epoch.ms;
        self.items[self.len] = bound;
        self.len += 1;
    }

    pub fn nextAfter(self: *const Queue, epoch: Epoch) ?Epoch {
        var best: ?u64 = null;
        for (self.items[0..self.len]) |c| {
            if (c.apply_at_epoch > epoch.ms) best = @min(c.apply_at_epoch, best orelse c.apply_at_epoch);
        }
        return if (best) |ms| .{ .ms = ms } else null;
    }

    pub fn applyDue(self: *Queue, gpa: std.mem.Allocator, log: *Log, epoch: Epoch, out: []Applied) error{OutOfMemory}!usize {
        std.debug.assert(self.len <= out.len);
        var capacity_needed: Log.Capacity = .{};
        for (self.items[0..self.len]) |c| {
            if (c.apply_at_epoch <= epoch.ms) capacity_needed.include(c);
        }
        try log.reserve(gpa, capacity_needed);

        var kept: usize = 0;
        var taken: usize = 0;
        for (self.items[0..self.len]) |c| {
            if (c.apply_at_epoch <= epoch.ms) {
                var bound = c;
                bound.apply_at_epoch = epoch.ms;
                log.addAssumeCapacity(bound);
                out[taken] = .{ .epoch = epoch, .command = c };
                taken += 1;
            } else {
                self.items[kept] = c;
                kept += 1;
            }
        }
        self.len = kept;
        self.taken += taken;
        return taken;
    }
};
