const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const bundle = @import("../bundle.zig");
const messages = @import("messages.zig");
const channels = @import("channels.zig");
const Broadcast = @import("ionosphere.zig").Broadcast;
const Log = @import("commands.zig").Log;
const types = core.types;
const GpsTime = core.time.GpsTime;
const Epoch = core.time.Epoch;
const NavFamily = types.NavFamily;
const State = channels.State;

fn Generations(comptime S: type) type {
    return ?*[2]S;
}

pub const Held = struct { key: types.ChannelKey, track: usize };

pub const Change = struct { track: usize, signal: types.Signal, state: State };

pub const Due = struct { at: GpsTime, families: std.EnumSet(NavFamily) };

pub const Window = struct { from: GpsTime, until: GpsTime };

pub const View = struct {
    window: Window,
    snapshot: messages.Snapshot,

    pub fn forSignal(self: View, signal: types.Signal) ?messages.MessageSet {
        return messages.forSignal(self.snapshot, signal);
    }
};

fn windowAt(b: *const bundle.Bundle, system: types.System, t: GpsTime) Window {
    var from = b.scenario.start;
    var until = bundle.plan.nextLegBoundary(system, from, b.plan.leap);
    while (!t.lessThan(until)) {
        from = until;
        until = bundle.plan.nextLegBoundary(system, from, b.plan.leap);
    }
    return .{ .from = from, .until = until };
}

pub const InitError = error{ OutOfMemory, MessageSet };

pub const Sequence = struct {
    b: *const bundle.Bundle,
    allocation: *const gnss.allocation.Allocation,
    broadcast: Broadcast,
    kinds: std.EnumSet(NavFamily),
    prepared: messages.Messages,
    sets: messages.Sets(Generations),
    current: std.EnumArray(NavFamily, u1) = .initFill(0),
    next: std.EnumArray(types.System, GpsTime) = undefined,
    rules: channels.Rules,
    log: *const Log,
    sats: []const types.SatId,
    states: []std.EnumArray(types.Signal, State),
    held: std.ArrayList(Held) = .empty,
    changes: std.ArrayList(Change) = .empty,

    pub fn init(gpa: std.mem.Allocator, prepared: messages.Messages, b: *const bundle.Bundle, allocation: *const gnss.allocation.Allocation, broadcast: Broadcast, samples: bundle.scenario.Samples, log: *const Log, sats: []const types.SatId) InitError!Sequence {
        const scenario = &b.scenario;
        const kinds = messages.familiesOf(scenario.signals);

        var sets: messages.Sets(Generations) = .{};
        errdefer freeSets(gpa, sets);
        inline for (comptime std.enums.values(NavFamily)) |family| {
            if (kinds.contains(family)) @field(sets, @tagName(family)) = try gpa.create([2]messages.Set(family));
        }

        const states = try gpa.alloc(std.EnumArray(types.Signal, State), sats.len);
        errdefer gpa.free(states);

        var count: usize = 0;
        var it = scenario.signals.iterator();
        while (it.next()) |signal| {
            for (sats) |sat| {
                if (sat.system == signal.system()) count += 1;
            }
        }
        var held = try std.ArrayList(Held).initCapacity(gpa, count);
        errdefer held.deinit(gpa);
        const changes = try std.ArrayList(Change).initCapacity(gpa, count * 2);

        return .{
            .b = b,
            .allocation = allocation,
            .broadcast = broadcast,
            .kinds = kinds,
            .prepared = prepared,
            .sets = sets,
            .rules = .{ .allocation = allocation, .samples = samples },
            .log = log,
            .sats = sats,
            .states = states,
            .held = held,
            .changes = changes,
        };
    }

    pub fn deinit(self: *Sequence, gpa: std.mem.Allocator) void {
        self.changes.deinit(gpa);
        self.held.deinit(gpa);
        gpa.free(self.states);
        freeSets(gpa, self.sets);
    }

    pub fn reset(self: *Sequence, sources: messages.Sources) error{MessageSet}!void {
        @memset(self.states, .initFill(.no_record));
        self.held.clearRetainingCapacity();
        self.changes.clearRetainingCapacity();
        self.current = .initFill(0);
        const start = self.b.scenario.start;
        for (types.System.all) |system| self.next.set(system, bundle.plan.nextLegBoundary(system, start, self.b.plan.leap));
        try self.build(self.kinds, start, sources);
    }

    fn build(self: *Sequence, families: std.EnumSet(NavFamily), t: GpsTime, sources: messages.Sources) error{MessageSet}!void {
        inline for (comptime std.enums.values(NavFamily)) |family| {
            if (families.contains(family)) {
                const next = self.current.get(family) ^ 1;
                try self.buildSet(family, &@field(self.sets, @tagName(family)).?[next], t, sources);
                self.current.set(family, next);
            }
        }
    }

    fn buildSet(self: *const Sequence, comptime family: NavFamily, out: *messages.Set(family), t: GpsTime, sources: messages.Sources) error{MessageSet}!void {
        messages.build(family, out, self.b, self.allocation, &self.broadcast, self.prepared, sources, t) catch return error.MessageSet;
    }

    pub fn viewAt(self: *const Sequence, arena: std.mem.Allocator, signal: types.Signal, t: GpsTime) error{ OutOfMemory, MessageSet }!?View {
        const family = gnss.spec.get(signal).family;
        if (!self.kinds.contains(family)) return null;
        const window = windowAt(self.b, family.system(), t);
        switch (family) {
            inline else => |f| {
                const set = try arena.create(messages.Set(f));
                try self.buildSet(f, set, window.from, .{});
                var snap: messages.Snapshot = .{};
                @field(snap, @tagName(f)) = set;
                const start = self.b.scenario.start;
                const from = channels.replanOnOrAfter(.{ .ms = @intCast(window.from.ms - start.ms) });
                const until = channels.replanOnOrAfter(.{ .ms = @intCast(window.until.ms - start.ms) });
                return .{
                    .window = .{
                        .from = core.time.atEpoch(start, from),
                        .until = core.time.atEpoch(start, until),
                    },
                    .snapshot = snap,
                };
            },
        }
    }

    pub fn due(self: *Sequence, to: GpsTime) ?Due {
        var at: ?GpsTime = null;
        var it = self.kinds.iterator();
        while (it.next()) |family| {
            const t = self.next.get(family.system());
            if (to.lessThan(t)) continue;
            if (at == null or t.lessThan(at.?)) at = t;
        }
        const when = at orelse return null;
        var families = std.EnumSet(NavFamily).empty;
        it = self.kinds.iterator();
        while (it.next()) |family| if (self.next.get(family.system()).eql(when)) families.insert(family);
        for (types.System.all) |system| {
            if (self.next.get(system).eql(when)) self.next.set(system, bundle.plan.nextLegBoundary(system, when, self.b.plan.leap));
        }
        return .{ .at = when, .families = families };
    }

    pub fn refresh(self: *Sequence, d: Due, sources: messages.Sources) messages.Failure!void {
        try self.build(d.families, d.at, sources);
        const snap = self.snapshot();
        for (self.held.items) |h| {
            if (!d.families.contains(gnss.spec.get(h.key.signal).family)) continue;
            if (messages.forSignal(snap, h.key.signal)) |set| try set.requireData(h.key.sat.prn());
        }
    }

    pub fn setsAt(self: *Sequence, t: GpsTime) error{MessageSet}!void {
        for (types.System.all) |system| {
            const window = windowAt(self.b, system, t);
            var families = std.EnumSet(NavFamily).empty;
            var it = self.kinds.iterator();
            while (it.next()) |family| if (family.system() == system) families.insert(family);
            try self.build(families, window.from, .{});
            self.next.set(system, window.until);
        }
    }

    pub fn snapshot(self: *const Sequence) messages.Snapshot {
        var snap: messages.Snapshot = .{};
        inline for (comptime std.enums.values(NavFamily)) |family| {
            if (@field(self.sets, @tagName(family))) |pair| @field(snap, @tagName(family)) = &pair[self.current.get(family)];
        }
        return snap;
    }

    pub fn replan(self: *Sequence, sights: []const ?channels.Sight, r: Epoch) messages.MissingData!void {
        self.changes.clearRetainingCapacity();
        const mask_rad = self.log.maskAt(self.b.scenario.elevation_mask_rad, r);
        const snap = self.snapshot();

        for (self.held.items) |h| {
            const state = channels.keep(h.key, sights[h.track], mask_rad, snap);
            if (state != .held) self.record(h.track, h.key.signal, state);
        }

        var it = self.b.scenario.signals.iterator();
        while (it.next()) |signal| {
            for (self.sats, 0..) |sat, track| {
                if (sat.system != signal.system()) continue;
                const key = types.ChannelKey.init(sat, signal);
                const was = self.states[track].get(signal);
                const previous = if (was == .held) channels.keep(key, sights[track], mask_rad, snap) else was;
                if (previous == .held) continue;
                const state = try self.rules.admit(key, sights[track], mask_rad, snap);
                if (state != previous) self.record(track, signal, state);
            }
        }

        for (self.changes.items) |c| self.redo(c);
    }

    fn record(self: *Sequence, track: usize, signal: types.Signal, state: State) void {
        self.changes.appendAssumeCapacity(.{ .track = track, .signal = signal, .state = state });
    }

    pub fn restore(self: *Sequence, states: []const std.EnumArray(types.Signal, State), held: []const Held) void {
        @memcpy(self.states, states);
        self.held.clearRetainingCapacity();
        self.held.appendSliceAssumeCapacity(held);
    }

    pub fn redo(self: *Sequence, c: Change) void {
        const was = self.states[c.track].get(c.signal);
        self.states[c.track].set(c.signal, c.state);
        const key = types.ChannelKey.init(self.sats[c.track], c.signal);
        if (c.state == .held) {
            self.held.appendAssumeCapacity(.{ .key = key, .track = c.track });
        } else if (was == .held) {
            for (self.held.items, 0..) |h, j| if (h.key == key) {
                _ = self.held.orderedRemove(j);
                break;
            };
        }
    }
};

fn freeSets(gpa: std.mem.Allocator, sets: messages.Sets(Generations)) void {
    inline for (comptime std.enums.values(NavFamily)) |family| {
        if (@field(sets, @tagName(family))) |pair| gpa.destroy(pair);
    }
}
