const std = @import("std");
const time = @import("domain/time/gps");
const tracking = @import("simulation/tracking/track");
const binding = @import("simulation/tracking/binding");
const trajectory = @import("domain/trajectory/trajectory");
const flight = @import("simulation/model/flight_plan");
const orbit_constants = @import("domain/navigation/orbit/constants");
const geometry = @import("simulation/geometry/geometry");
const receiver = @import("simulation/geometry/receiver");
const gnss_types = @import("domain/gnss_types");

const Payload = @import("domain/signals/payload").Payload;

const GpsTime = time.GpsTime;
const Epoch = time.Epoch;
const Mark = tracking.Mark;

pub const Inputs = struct {
    ephemerides: binding.Inputs,
    trajectory: *const trajectory.Trajectory,
    start: GpsTime,
};

pub const Move = enum { kept, shifted, begun };

pub const Track = struct {
    sat: gnss_types.SatId,
    ephemeris: tracking.Track = .{},
    knots: ?[2]geometry.Knot = null,
    move: Move = .kept,

    pub fn advanceTo(self: *Track, input: binding.Inputs, t: GpsTime) tracking.Advance {
        const out = self.ephemeris.advanceTo(input, self.sat, t);
        if (out.refreshed) self.knots = null;
        return out;
    }

    pub fn ready(self: *const Track) ?geometry.Ready {
        return if (self.knots) |*k| .{ .sat = self.sat, .knots = k } else null;
    }

    pub fn look(self: *Track, rx: receiver.Frame, t: GpsTime) geometry.Look {
        const state = self.ephemeris.stateAt(t);
        return geometry.look(&self.ephemeris, rx, t, self.omegaEarth(), state.pos);
    }

    pub fn nextInstant(self: *const Track, flight_plan: *const flight.FlightPlan) GpsTime {
        return self.ephemeris.nextInstant(flight_plan, self.sat);
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
        return orbit_constants.get(self.sat.system).omega_e;
    }
};

pub const Window = struct {
    input: Inputs,
    tracks: []Track,
    base_epoch: ?Epoch = null,
    ends: [2]receiver.Frame = undefined,
    move: Move = .kept,

    pub fn init(gpa: std.mem.Allocator, input: Inputs, signals: std.EnumSet(gnss_types.Signal), payload: *const Payload, mask_out: std.EnumArray(gnss_types.System, gnss_types.SatSet)) std.mem.Allocator.Error!Window {
        const tracks = try tracksOf(gpa, signals, mask_out, payload);
        return .{ .input = input, .tracks = tracks };
    }

    pub fn deinit(self: *Window, gpa: std.mem.Allocator) void {
        gpa.free(self.tracks);
    }

    pub fn reset(self: *Window) void {
        for (self.tracks) |*t| t.* = .{ .sat = t.sat };
        self.base_epoch = null;
    }

    pub fn mark(self: *const Window, out: []Mark) void {
        for (self.tracks, out) |*t, *m| m.* = t.ephemeris.mark();
    }

    pub fn restore(self: *Window, marks: []const Mark) void {
        for (self.tracks, marks) |*t, m| t.* = .{ .sat = t.sat, .ephemeris = .restore(self.input.ephemerides, t.sat, m) };
        self.base_epoch = null;
    }

    pub fn base(self: *const Window) Epoch {
        return self.base_epoch.?;
    }

    pub fn advance(self: *Window, epoch: Epoch) std.EnumArray(gnss_types.System, gnss_types.SatSet) {
        return self.advanceSelection(epoch, null);
    }

    pub fn advanceTarget(self: *Window, epoch: Epoch, sat: gnss_types.SatId) std.EnumArray(gnss_types.System, gnss_types.SatSet) {
        return self.advanceSelection(epoch, sat);
    }

    fn advanceSelection(self: *Window, epoch: Epoch, target: ?gnss_types.SatId) std.EnumArray(gnss_types.System, gnss_types.SatSet) {
        self.move = self.enter(.{ .ms = epoch.ms - epoch.ms % time.epochs_per_second });
        const t_a = self.at(self.base());
        const t = self.at(epoch);
        var switched: std.EnumArray(gnss_types.System, gnss_types.SatSet) = .initFill(.{});
        for (self.tracks) |*tr| {
            const result = tr.advanceTo(self.input.ephemerides, t);
            tr.move = if (result.refreshed or tr.knots == null) .begun else self.move;
            if (result.switched) switched.getPtr(tr.sat.system).insert(tr.sat);
            if (target) |sat| if (sat != tr.sat) {
                if (self.move != .kept or result.refreshed) tr.knots = null;
                continue;
            };
            switch (tr.move) {
                .kept => {},
                .shifted => tr.shift(self.ends[1]),
                .begun => tr.fill(t_a, self.ends),
            }
        }
        return switched;
    }

    fn enter(self: *Window, to: Epoch) Move {
        if (self.base_epoch) |current| {
            if (to.ms == current.ms) return .kept;
            if (to.ms == current.plus(time.epochs_per_second).ms) {
                self.ends = .{ self.ends[1], self.end(to.plus(time.epochs_per_second)) };
                self.base_epoch = to;
                return .shifted;
            }
        }
        self.ends = .{ self.end(to), self.end(to.plus(time.epochs_per_second)) };
        self.base_epoch = to;
        return .begun;
    }

    fn at(self: *const Window, epoch: Epoch) GpsTime {
        return time.atEpoch(self.input.start, epoch);
    }

    fn end(self: *const Window, epoch: Epoch) receiver.Frame {
        return receiver.atMs(self.input.trajectory, epoch.ms);
    }
};

pub fn tracksOf(gpa: std.mem.Allocator, signals: std.EnumSet(gnss_types.Signal), mask_out: std.EnumArray(gnss_types.System, gnss_types.SatSet), payload: *const Payload) std.mem.Allocator.Error![]Track {
    var tracks: std.ArrayList(Track) = .empty;
    errdefer tracks.deinit(gpa);
    for (gnss_types.System.all) |system| {
        var sats = system.satellites();
        while (sats.next()) |sat| {
            if (mask_out.get(system).contains(sat) or !payload.transmitsAny(sat, signals)) continue;
            try tracks.append(gpa, .{ .sat = sat });
        }
    }
    return tracks.toOwnedSlice(gpa);
}
