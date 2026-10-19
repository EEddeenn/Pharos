const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const bundle = shared.bundle;
const geo = shared.geo;
const stage = shared.stage;
const Mark = shared.track.provider.Mark;
const types = core.types;
const Epoch = core.time.Epoch;
const channels = stage.channels;
const sequence = stage.sequence;
const State = channels.State;
const States = std.EnumArray(types.Signal, State);

const checkpoint_ms: u64 = 600_000;

const Logged = struct { epoch: Epoch, change: sequence.Change };

const Snapshot = struct {
    epoch: Epoch,
    logged: usize,
    states: []States,
    held: std.ArrayList(sequence.Held),
    marks: []Mark,

    fn deinit(self: Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.marks);
        var held = self.held;
        held.deinit(gpa);
        gpa.free(self.states);
    }
};

pub const Replay = struct {
    gpa: std.mem.Allocator,
    b: *const bundle.Bundle,
    span: bundle.Span,
    seq: sequence.Sequence,
    tracks: []geo.window.Track,
    sats: []types.SatId,
    sights: []?channels.Sight,
    changes: std.ArrayList(Logged) = .empty,
    base: ?Snapshot = null,
    snapshots: std.ArrayList(Snapshot) = .empty,
    planned: ?Epoch = null,
    rewind: ?Epoch = null,
    stale: bool = false,
    past: []States,
    indices: [256]?u8 = @splat(null),
    past_epoch: ?Epoch = null,
    views: std.EnumArray(types.NavFamily, CachedView),

    pub fn deinit(self: *Replay) void {
        const gpa = self.gpa;
        for (&self.views.values) |*view| view.arena.deinit();
        for (self.snapshots.items) |p| p.deinit(gpa);
        self.snapshots.deinit(gpa);
        if (self.base) |p| p.deinit(gpa);
        self.changes.deinit(gpa);
        self.seq.deinit(gpa);
        gpa.free(self.past);
        gpa.free(self.sights);
        gpa.free(self.sats);
        gpa.free(self.tracks);
    }

    fn reserveSnapshot(self: *const Replay, gpa: std.mem.Allocator, r: Epoch) error{OutOfMemory}!Snapshot {
        const states = try gpa.alloc(States, self.seq.states.len);
        errdefer gpa.free(states);
        var held = try std.ArrayList(sequence.Held).initCapacity(gpa, self.seq.held.capacity);
        errdefer held.deinit(gpa);
        const marks = try gpa.alloc(Mark, self.tracks.len);
        return .{ .epoch = r, .logged = 0, .states = states, .held = held, .marks = marks };
    }

    fn capture(self: *const Replay, out: *Snapshot) void {
        out.logged = self.changes.items.len;
        @memcpy(out.states, self.seq.states);
        out.held.appendSliceAssumeCapacity(self.seq.held.items);
        for (self.tracks, out.marks) |*track, *m| m.* = track.ephemeris.mark();
    }

    pub fn init(gpa: std.mem.Allocator, b: *const bundle.Bundle, allocation: *const gnss.allocation.Allocation, prepared: stage.messages.Messages, log: *const stage.commands.Log) (error{OutOfMemory} || stage.messages.Failure)!Replay {
        const scenario = &b.scenario;
        const tracks = try geo.window.tracksOf(gpa, scenario.signals, scenario.mask_out, allocation);
        errdefer gpa.free(tracks);
        const sats = try gpa.alloc(types.SatId, tracks.len);
        errdefer gpa.free(sats);
        for (sats, tracks) |*sat, track| sat.* = track.sat;
        const sights = try gpa.alloc(?channels.Sight, tracks.len);
        errdefer gpa.free(sights);
        const past = try gpa.alloc(States, tracks.len);
        errdefer gpa.free(past);
        const initial_log: stage.commands.Log = .{};
        var seq = try sequence.Sequence.init(gpa, prepared, b, allocation, scenario.ionosphere.ready.broadcast, scenario.samples.?, &initial_log, sats);
        errdefer seq.deinit(gpa);
        try seq.reset(.{});
        var self: Replay = .{
            .gpa = gpa,
            .b = b,
            .span = b.span(),
            .seq = seq,
            .tracks = tracks,
            .sats = sats,
            .sights = sights,
            .past = past,
            .views = undefined,
        };
        for (&self.views.values) |*view| view.* = .{ .arena = .init(gpa) };
        errdefer self.changes.deinit(gpa);
        for (sats, 0..) |sat, i| self.indices[sat.key()] = @intCast(i);
        try self.replan(.zero);
        self.base = try self.reserveSnapshot(gpa, .zero);
        self.capture(&self.base.?);
        self.seq.log = log;
        return self;
    }

    pub fn invalidate(self: *Replay, epoch: Epoch) void {
        const furthest = self.planned orelse return;
        const to = channels.replanOnOrAfter(epoch);
        if (to.ms > furthest.ms) return;
        if (self.rewind) |pending| if (pending.ms <= to.ms) return;
        self.rewind = to;
        self.past_epoch = null;
    }

    pub fn state(self: *const Replay, states: []const States, sat: types.SatId, signal: types.Signal) State {
        const index = self.indices[sat.key()] orelse return .masked_out;
        return states[index].get(signal);
    }

    pub fn viewAt(self: *Replay, signal: types.Signal, t: core.time.GpsTime) error{ OutOfMemory, MessageSet }!?sequence.View {
        const family = gnss.spec.get(signal).family;
        if (!self.seq.kinds.contains(family)) return null;
        const cached = self.views.getPtr(family);
        if (cached.view) |view| {
            if (!t.lessThan(view.window.from) and t.lessThan(view.window.until)) return view;
        }
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const view = try self.seq.viewAt(arena.allocator(), signal, t);
        cached.arena.deinit();
        cached.* = .{ .arena = arena, .view = view };
        return view;
    }

    fn rewindTo(self: *Replay, to: Epoch) void {
        const gpa = self.gpa;
        while (self.snapshots.last()) |last| {
            if (last.epoch.ms < to.ms) break;
            last.deinit(gpa);
            self.snapshots.items.len -= 1;
        }
        const from = self.snapshots.last() orelse self.base.?;
        self.seq.restore(from.states, from.held.items);
        var k = from.logged;
        while (k < self.changes.items.len and self.changes.items[k].epoch.ms < to.ms) : (k += 1) self.seq.redo(self.changes.items[k].change);
        self.changes.shrinkRetainingCapacity(k);
        for (self.tracks, from.marks) |*track, m| track.* = .{ .sat = track.sat, .ephemeris = .restore(self.b, track.sat, m) };
        self.planned = if (to.ms == 0) null else .{ .ms = to.ms - channels.replan_epochs };
        self.stale = true;
        self.past_epoch = null;
    }

    pub fn advance(self: *Replay, r: Epoch) (error{OutOfMemory} || stage.messages.Failure)!void {
        if (self.rewind) |to| {
            self.rewindTo(to);
            self.rewind = null;
        }
        if (self.stale) {
            try self.seq.setsAt(core.time.atEpoch(self.span.start, self.planned orelse .zero));
            self.stale = false;
        }
        var next: Epoch = if (self.planned) |p| p.plus(channels.replan_epochs) else .zero;
        while (next.ms <= r.ms) : (next = next.plus(channels.replan_epochs)) {
            var taken: ?Snapshot = null;
            if (next.ms % checkpoint_ms == 0) {
                try self.snapshots.ensureUnusedCapacity(self.gpa, 1);
                taken = try self.reserveSnapshot(self.gpa, next);
            }
            errdefer if (taken) |s| s.deinit(self.gpa);
            try self.replan(next);
            if (taken) |*s| {
                self.capture(s);
                self.snapshots.appendAssumeCapacity(s.*);
            }
            self.planned = next;
        }
    }

    fn replan(self: *Replay, r: Epoch) (error{OutOfMemory} || stage.messages.Failure)!void {
        try self.changes.ensureUnusedCapacity(self.gpa, self.seq.changes.capacity);
        errdefer self.rewind = r;
        const t = core.time.atEpoch(self.span.start, r);
        while (self.seq.due(t)) |due| try self.seq.refresh(due, .{});
        const rx = geo.receiver.atMs(&self.b.trajectory, r.ms);
        for (self.tracks, self.sights) |*track, *sight| {
            _ = track.advanceTo(self.b, t);
            sight.* = if (track.ephemeris.current) |current| .{ .air = current.air, .freq = current.record.freq(), .el_rad = track.look(rx, t).el_rad } else null;
        }
        try self.seq.replan(self.sights, r);
        for (self.seq.changes.items) |c| self.changes.appendAssumeCapacity(.{ .epoch = r, .change = c });
    }

    pub fn statesAt(self: *Replay, r: Epoch) []const States {
        if (self.planned.?.ms == r.ms) return self.seq.states;
        if (self.past_epoch) |previous| if (previous.ms == r.ms) return self.past;
        var i = self.snapshots.items.len;
        while (self.snapshots.items[i - 1].epoch.ms > r.ms) i -= 1;
        const from = self.snapshots.items[i - 1];
        @memcpy(self.past, from.states);
        for (self.changes.items[from.logged..]) |l| {
            if (l.epoch.ms > r.ms) break;
            self.past[l.change.track].set(l.change.signal, l.change.state);
        }
        self.past_epoch = r;
        return self.past;
    }
};

const CachedView = struct {
    arena: std.heap.ArenaAllocator,
    view: ?sequence.View = null,
};
