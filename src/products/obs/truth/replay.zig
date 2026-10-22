const std = @import("std");
const time = @import("domain/time/gps");
const binding = @import("simulation/tracking/binding");
const trajectory = @import("domain/trajectory/trajectory");
const configuration = @import("simulation/model/config");
const windows = @import("simulation/geometry/window");
const command_log = @import("simulation/state/commands");
const receiver = @import("simulation/geometry/receiver");
const gnss_types = @import("domain/gnss_types");
const channels = @import("simulation/state/channels");

const Payload = @import("domain/signals/payload").Payload;
const Mark = @import("simulation/tracking/track").Mark;

const Epoch = time.Epoch;
const State = channels.State;
const States = std.EnumArray(gnss_types.Signal, State);

const checkpoint_ms: u64 = 600_000;

const Logged = struct { epoch: Epoch, change: channels.Change };

const Snapshot = struct {
    epoch: Epoch,
    logged: usize,
    states: []States,
    held: std.ArrayList(channels.Held),
    marks: []Mark,

    fn deinit(self: Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.marks);
        var held = self.held;
        held.deinit(gpa);
        gpa.free(self.states);
    }
};

pub const Inputs = struct {
    ephemerides: binding.Inputs,
    trajectory: *const trajectory.Trajectory,
    start: time.GpsTime,
    signals: std.EnumSet(gnss_types.Signal),
    mask_out: std.EnumArray(gnss_types.System, gnss_types.SatSet),
    samples: configuration.Samples,
    elevation_mask_rad: f64,
};

pub const Replay = struct {
    gpa: std.mem.Allocator,
    ephemerides: binding.Inputs,
    trajectory: *const trajectory.Trajectory,
    start: time.GpsTime,
    selection: channels.Selection,
    tracks: []windows.Track,
    sats: []gnss_types.SatId,
    sights: []?channels.Sight,
    changes: std.ArrayList(Logged) = .empty,
    initial: Snapshot,
    checkpoints: std.ArrayList(Snapshot) = .empty,
    planned: ?Epoch = null,
    rewind: ?Epoch = null,
    past: []States,
    indices: [256]?u8 = @splat(null),
    past_epoch: ?Epoch = null,

    pub fn init(gpa: std.mem.Allocator, input: Inputs, payload: *const Payload, log: *const command_log.Log) error{OutOfMemory}!Replay {
        const tracks = try windows.tracksOf(gpa, input.signals, input.mask_out, payload);
        errdefer gpa.free(tracks);
        const sats = try gpa.alloc(gnss_types.SatId, tracks.len);
        errdefer gpa.free(sats);
        for (sats, tracks) |*sat, track| sat.* = track.sat;
        const sights = try gpa.alloc(?channels.Sight, tracks.len);
        errdefer gpa.free(sights);
        const past = try gpa.alloc(States, tracks.len);
        errdefer gpa.free(past);
        const initial_log: command_log.Log = .{};
        var selection = try channels.Selection.init(gpa, .{ .payload = payload, .samples = input.samples }, input.signals, input.elevation_mask_rad, &initial_log, sats);
        errdefer selection.deinit(gpa);
        var self: Replay = .{
            .gpa = gpa,
            .ephemerides = input.ephemerides,
            .trajectory = input.trajectory,
            .start = input.start,
            .selection = selection,
            .tracks = tracks,
            .sats = sats,
            .sights = sights,
            .past = past,
            .initial = undefined,
        };
        errdefer self.changes.deinit(gpa);
        for (sats, 0..) |sat, i| self.indices[sat.key()] = @intCast(i);
        try self.replan(.zero);
        self.initial = try self.reserveSnapshot(gpa, .zero);
        self.capture(&self.initial);
        self.selection.log = log;
        return self;
    }

    pub fn deinit(self: *Replay) void {
        const gpa = self.gpa;
        for (self.checkpoints.items) |p| p.deinit(gpa);
        self.checkpoints.deinit(gpa);
        self.initial.deinit(gpa);
        self.changes.deinit(gpa);
        self.selection.deinit(gpa);
        gpa.free(self.past);
        gpa.free(self.sights);
        gpa.free(self.sats);
        gpa.free(self.tracks);
    }

    pub fn invalidate(self: *Replay, epoch: Epoch) void {
        const furthest = self.planned orelse return;
        const to = channels.replanOnOrAfter(epoch);
        if (to.ms > furthest.ms) return;
        if (self.rewind) |pending| if (pending.ms <= to.ms) return;
        self.rewind = to;
        self.past_epoch = null;
    }

    pub fn state(self: *const Replay, states: []const States, sat: gnss_types.SatId, signal: gnss_types.Signal) State {
        const index = self.indices[sat.key()] orelse return .masked_out;
        return states[index].get(signal);
    }

    pub fn advance(self: *Replay, r: Epoch) error{OutOfMemory}!void {
        if (self.rewind) |to| {
            self.rewindTo(to);
            self.rewind = null;
        }
        var next: Epoch = if (self.planned) |p| p.plus(channels.replan_epochs) else .zero;
        while (next.ms <= r.ms) : (next = next.plus(channels.replan_epochs)) {
            var taken: ?Snapshot = null;
            if (next.ms % checkpoint_ms == 0) {
                try self.checkpoints.ensureUnusedCapacity(self.gpa, 1);
                taken = try self.reserveSnapshot(self.gpa, next);
            }
            errdefer if (taken) |s| s.deinit(self.gpa);
            try self.replan(next);
            if (taken) |*s| {
                self.capture(s);
                self.checkpoints.appendAssumeCapacity(s.*);
            }
            self.planned = next;
        }
    }

    pub fn statesAt(self: *Replay, r: Epoch) []const States {
        if (self.planned.?.ms == r.ms) return self.selection.states;
        if (self.past_epoch) |previous| if (previous.ms == r.ms) return self.past;
        var i = self.checkpoints.items.len;
        while (self.checkpoints.items[i - 1].epoch.ms > r.ms) i -= 1;
        const from = self.checkpoints.items[i - 1];
        @memcpy(self.past, from.states);
        for (self.changes.items[from.logged..]) |l| {
            if (l.epoch.ms > r.ms) break;
            self.past[l.change.track].set(l.change.signal, l.change.state());
        }
        self.past_epoch = r;
        return self.past;
    }

    fn reserveSnapshot(self: *const Replay, gpa: std.mem.Allocator, r: Epoch) error{OutOfMemory}!Snapshot {
        const states = try gpa.alloc(States, self.selection.states.len);
        errdefer gpa.free(states);
        var held = try std.ArrayList(channels.Held).initCapacity(gpa, self.selection.held.capacity);
        errdefer held.deinit(gpa);
        const marks = try gpa.alloc(Mark, self.tracks.len);
        return .{ .epoch = r, .logged = 0, .states = states, .held = held, .marks = marks };
    }

    fn capture(self: *const Replay, out: *Snapshot) void {
        out.logged = self.changes.items.len;
        @memcpy(out.states, self.selection.states);
        out.held.appendSliceAssumeCapacity(self.selection.held.items);
        for (self.tracks, out.marks) |*track, *m| m.* = track.ephemeris.mark();
    }

    fn rewindTo(self: *Replay, to: Epoch) void {
        const gpa = self.gpa;
        while (self.checkpoints.last()) |last| {
            if (last.epoch.ms < to.ms) break;
            last.deinit(gpa);
            self.checkpoints.items.len -= 1;
        }
        const from = self.checkpoints.last() orelse self.initial;
        self.selection.restore(from.states, from.held.items);
        var k = from.logged;
        while (k < self.changes.items.len and self.changes.items[k].epoch.ms < to.ms) : (k += 1) self.selection.redo(self.changes.items[k].change);
        self.changes.shrinkRetainingCapacity(k);
        for (self.tracks, from.marks) |*track, m| track.* = .{ .sat = track.sat, .ephemeris = .restore(self.ephemerides, track.sat, m) };
        self.planned = if (to.ms == 0) null else .{ .ms = to.ms - channels.replan_epochs };
        self.past_epoch = null;
    }

    fn replan(self: *Replay, r: Epoch) error{OutOfMemory}!void {
        try self.changes.ensureUnusedCapacity(self.gpa, self.selection.changes.capacity);
        const t = time.atEpoch(self.start, r);
        const rx = receiver.atMs(self.trajectory, r.ms);
        for (self.tracks, self.sights) |*track, *sight| {
            _ = track.advanceTo(self.ephemerides, t);
            sight.* = if (track.ephemeris.current) |current| .{ .air = current.selection.binding.air, .freq = current.selection.binding.freq, .el_rad = track.look(rx, t).el_rad } else null;
        }
        self.selection.replan(self.sights, r);
        for (self.selection.changes.items) |c| self.changes.appendAssumeCapacity(.{ .epoch = r, .change = c });
    }
};
