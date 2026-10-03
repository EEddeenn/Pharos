const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const bundle = @import("../bundle.zig");
const track = @import("../track.zig");
const geometry = @import("geometry.zig");
const receiver = @import("receiver.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const Epoch = core.time.Epoch;
const Mark = track.provider.Mark;

pub const Move = enum { kept, shifted, begun };

pub fn tracksOf(gpa: std.mem.Allocator, signals: std.EnumSet(types.Signal), mask_out: std.EnumArray(types.System, types.SatSet), allocation: *const gnss.allocation.Allocation) std.mem.Allocator.Error![]Track {
    var tracks: std.ArrayList(Track) = .empty;
    errdefer tracks.deinit(gpa);
    for (types.System.all) |system| {
        var sats = system.satellites();
        while (sats.next()) |sat| {
            if (mask_out.get(system).contains(sat) or !allocation.transmitsAny(sat, signals)) continue;
            try tracks.append(gpa, .{ .sat = sat });
        }
    }
    return tracks.toOwnedSlice(gpa);
}

pub const Track = struct {
    sat: types.SatId,
    ephemeris: track.provider.Track = .{},
    knots: ?[2]geometry.Knot = null,
    move: Move = .kept,

    pub fn advanceTo(self: *Track, b: *const bundle.Bundle, t: GpsTime) track.provider.Advance {
        const out = self.ephemeris.advanceTo(b, self.sat, t);
        if (out.refreshed) self.knots = null;
        return out;
    }

    pub fn ready(self: *const Track) ?geometry.Ready {
        return if (self.knots) |*k| .{ .sat = self.sat, .knots = k } else null;
    }

    pub fn record(self: *const Track) ?track.selection.Record {
        return if (self.ephemeris.current) |c| c.record else null;
    }

    pub fn look(self: *Track, rx: receiver.Frame, t: GpsTime) geometry.Look {
        const state = self.ephemeris.stateAt(t);
        return geometry.look(&self.ephemeris, rx, t, self.omegaEarth(), .{ .pos = state.pos, .vel = state.vel });
    }

    pub fn nextInstant(self: *const Track, b: *const bundle.Bundle) GpsTime {
        return self.ephemeris.nextInstant(b, self.sat);
    }

    fn fill(self: *Track, t: GpsTime, ends: [2]receiver.Frame) void {
        if (self.ephemeris.current == null) return;
        self.knots = .{
            geometry.knot(&self.ephemeris, ends[0], t, self.omegaEarth()),
            geometry.knot(&self.ephemeris, ends[1], t.addSeconds(1.0), self.omegaEarth()),
        };
    }

    fn shift(self: *Track, rx: receiver.Frame) void {
        const k = if (self.knots) |*filled| filled else return;
        k[0] = k[1];
        k[1] = geometry.knot(&self.ephemeris, rx, k[0].t.addSeconds(1.0), self.omegaEarth());
    }

    fn omegaEarth(self: *const Track) f64 {
        return gnss.constants.get(self.sat.system).omega_e;
    }
};

pub const Window = struct {
    b: *const bundle.Bundle,
    tracks: []Track,
    entries: []geometry.Entry,
    base_epoch: ?Epoch = null,
    ends: [2]receiver.Frame = undefined,
    move: Move = .kept,

    pub fn init(gpa: std.mem.Allocator, b: *const bundle.Bundle, allocation: *const gnss.allocation.Allocation, mask_out: std.EnumArray(types.System, types.SatSet)) std.mem.Allocator.Error!Window {
        const tracks = try tracksOf(gpa, b.scenario.signals, mask_out, allocation);
        errdefer gpa.free(tracks);
        const entries = try gpa.alloc(geometry.Entry, tracks.len);
        for (tracks, entries) |t, *entry| entry.* = .{ .sat = t.sat };
        return .{ .b = b, .tracks = tracks, .entries = entries };
    }

    pub fn deinit(self: *Window, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.tracks);
    }

    pub fn reset(self: *Window) void {
        for (self.tracks, self.entries) |*t, *entry| {
            t.* = .{ .sat = t.sat };
            entry.knots = null;
        }
        self.base_epoch = null;
    }

    pub fn mark(self: *const Window, out: []Mark) void {
        for (self.tracks, out) |*t, *m| m.* = t.ephemeris.mark();
    }

    pub fn restore(self: *Window, marks: []const Mark) void {
        for (self.tracks, self.entries, marks) |*t, *entry, m| {
            t.* = .{ .sat = t.sat, .ephemeris = .restore(self.b, t.sat, m) };
            entry.knots = null;
        }
        self.base_epoch = null;
    }

    pub fn base(self: *const Window) Epoch {
        return self.base_epoch.?;
    }

    pub fn frame(self: *const Window) geometry.Frame {
        return .{ .tracks = self.entries };
    }

    pub fn advance(self: *Window, epoch: Epoch) std.EnumArray(types.System, types.SatSet) {
        return self.advanceSelection(epoch, null);
    }

    pub fn advanceTarget(self: *Window, epoch: Epoch, sat: types.SatId) std.EnumArray(types.System, types.SatSet) {
        return self.advanceSelection(epoch, sat);
    }

    fn advanceSelection(self: *Window, epoch: Epoch, target: ?types.SatId) std.EnumArray(types.System, types.SatSet) {
        self.move = self.enter(.{ .ms = epoch.ms - epoch.ms % core.time.epochs_per_second });
        const t_a = self.at(self.base());
        const t = self.at(epoch);
        var switched: std.EnumArray(types.System, types.SatSet) = .initFill(.{});
        for (self.tracks, self.entries) |*tr, *entry| {
            const result = tr.advanceTo(self.b, t);
            tr.move = if (result.refreshed or tr.knots == null) .begun else self.move;
            if (result.switched) switched.getPtr(tr.sat.system).insert(tr.sat);
            if (target) |sat| if (!std.meta.eql(sat, tr.sat)) {
                if (self.move != .kept or result.refreshed) tr.knots = null;
                entry.knots = if (tr.knots) |*pair| pair else null;
                continue;
            };
            switch (tr.move) {
                .kept => {},
                .shifted => tr.shift(self.ends[1]),
                .begun => tr.fill(t_a, self.ends),
            }
            entry.knots = if (tr.knots) |*pair| pair else null;
        }
        return switched;
    }

    fn enter(self: *Window, to: Epoch) Move {
        if (self.base_epoch) |current| {
            if (to.ms == current.ms) return .kept;
            if (to.ms == current.plus(core.time.epochs_per_second).ms) {
                self.ends = .{ self.ends[1], self.end(to.plus(core.time.epochs_per_second)) };
                self.base_epoch = to;
                return .shifted;
            }
        }
        self.ends = .{ self.end(to), self.end(to.plus(core.time.epochs_per_second)) };
        self.base_epoch = to;
        return .begun;
    }

    fn at(self: *const Window, epoch: Epoch) GpsTime {
        return core.time.atEpoch(self.b.scenario.start, epoch);
    }

    fn end(self: *const Window, epoch: Epoch) receiver.Frame {
        return receiver.atMs(&self.b.trajectory, epoch.ms);
    }
};
