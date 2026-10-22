const std = @import("std");
const signal_catalog = @import("domain/signals/catalog");
const time = @import("domain/time/gps");
const observation_model = @import("simulation/geometry/observation");
const prepared_scenario = @import("simulation/model/prepared_scenario");
const receiver = @import("simulation/geometry/receiver");
const gnss_types = @import("domain/gnss_types");
const ionosphere_state = @import("simulation/state/ionosphere");
const signal_model = @import("domain/signals/model");
const physical = @import("domain/physical_constants");

const Power = @import("simulation/state/power").Power;

const ModelSet = ionosphere_state.ModelSet;

pub const CreateError = error{OutOfMemory};
pub const AdvanceError = error{ EpochOutOfRange, EpochPassed };
pub const ObservationCode = signal_model.Observable;

pub const Signal = struct {
    signal: gnss_types.Signal,
    pseudorange_m: [signal_catalog.max_observables]f64,
    phase_cycles: f64,
    doppler_hz: f64,
    cn0_dbhz: f64,
};

pub const Satellite = struct { sat: gnss_types.SatId, signals: []const Signal };
pub const Epoch = struct { t: time.GpsTime, sats: []const Satellite };

const Span = struct { first: usize, end: usize };

pub const ObservationCursor = struct {
    gpa: std.mem.Allocator,
    ionosphere: ModelSet,
    ionosphere_info: ionosphere_state.Info,
    last_epoch_ms: u64,
    advanced: ?time.Epoch = null,
    geometry: observation_model.Observation,
    spans: []Span,
    signals: []gnss_types.Signal,
    satellites: []Satellite,
    values: []Signal,

    pub fn create(gpa: std.mem.Allocator, b: *const prepared_scenario.PreparedScenario) CreateError!*ObservationCursor {
        const self = try gpa.create(ObservationCursor);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .ionosphere = try ModelSet.init(gpa, &b.config.ionosphere.ready),
            .ionosphere_info = .of(&b.config.ionosphere.ready, b.config.signals),
            .last_epoch_ms = b.epochs(),
            .geometry = undefined,
            .spans = &.{},
            .signals = &.{},
            .satellites = &.{},
            .values = &.{},
        };
        errdefer self.ionosphere.deinit(gpa);
        self.geometry = try observation_model.Observation.init(gpa, .{
            .ephemerides = .{ .flight_plan = &b.flight_plan, .precise = b.precise, .phase_centres = &b.phase_centres },
            .trajectory = &b.trajectory,
            .start = b.config.start,
        }, b.config.signals, &b.payload, &self.ionosphere.models, b.config.mask_out);
        errdefer self.geometry.deinit(gpa);
        const tracks = self.geometry.entries;
        self.spans = try gpa.alloc(Span, tracks.len);
        errdefer gpa.free(self.spans);
        var count: usize = 0;
        for (tracks, self.spans) |track, *span| {
            span.first = count;
            for (std.enums.values(gnss_types.Signal)) |signal| {
                if (b.config.signals.contains(signal) and b.payload.transmits(track.sat, signal)) count += 1;
            }
            span.end = count;
        }
        self.signals = try gpa.alloc(gnss_types.Signal, count);
        errdefer gpa.free(self.signals);
        for (tracks, self.spans) |track, span| {
            var next = span.first;
            for (std.enums.values(gnss_types.Signal)) |signal| {
                if (!b.config.signals.contains(signal) or !b.payload.transmits(track.sat, signal)) continue;
                self.signals[next] = signal;
                next += 1;
            }
        }
        self.satellites = try gpa.alloc(Satellite, tracks.len);
        errdefer gpa.free(self.satellites);
        self.values = try gpa.alloc(Signal, count);
        return self;
    }

    pub fn destroy(self: *ObservationCursor) void {
        const gpa = self.gpa;
        gpa.free(self.values);
        gpa.free(self.satellites);
        gpa.free(self.signals);
        gpa.free(self.spans);
        self.geometry.deinit(gpa);
        self.ionosphere.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn tracked(self: *const ObservationCursor) usize {
        return self.spans.len;
    }

    pub fn reset(self: *ObservationCursor) void {
        self.geometry.reset();
        self.advanced = null;
    }

    /// The returned slices borrow this cursor until its next advance, reset or destruction.
    pub fn advanceTo(self: *ObservationCursor, epoch: time.Epoch, mask_rad: f64, power: *const Power) AdvanceError!Epoch {
        if (epoch.ms > self.last_epoch_ms) return error.EpochOutOfRange;
        if (self.advanced) |previous| if (epoch.ms < previous.ms) return error.EpochPassed;
        return sampleEpoch(self, epoch, mask_rad, power);
    }

    fn project(self: *ObservationCursor, index: usize, ready: observation_model.Ready, sample: observation_model.Sample, power: *const Power, count: *usize, used: *usize) void {
        const sat = sample.center;
        const sat_id = self.geometry.entries[index].sat;
        const span = self.spans[index];
        const delays = ready.delaysAt(sat.t_rx);
        const freq = delays.freq;
        const cn0_dbhz = power.cn0(sat_id, sat.el_rad);
        const first = used.*;
        for (self.signals[span.first..span.end]) |signal| {
            if (delays.air[signal_catalog.slot(signal)].status != .on_air) continue;
            var pseudorange_m: [signal_catalog.max_observables]f64 = @splat(0);
            for (signal_catalog.get(signal).observables, 0..) |observable, i| {
                pseudorange_m[i] = observation_model.channelTravel(sat, signal, freq, delays.code(signal, observable.component)) * physical.light_speed;
            }
            self.values[used.*] = .{
                .signal = signal,
                .pseudorange_m = pseudorange_m,
                .phase_cycles = observation_model.channelPhase(sat, signal, freq, delays.carrier(signal)),
                .doppler_hz = sample.doppler.hz(signal, freq),
                .cn0_dbhz = cn0_dbhz + signal_catalog.realizedDb(signal),
            };
            used.* += 1;
        }
        if (used.* == first) return;
        self.satellites[count.*] = .{ .sat = sat_id, .signals = self.values[first..used.*] };
        count.* += 1;
    }
};

pub fn observationCodes(signal: gnss_types.Signal) []const ObservationCode {
    return signal_catalog.get(signal).observables;
}

// File owns a bounded, monotonic sampler; the public cursor applies its own query checks before this computation.
pub fn sampleEpoch(self: *ObservationCursor, epoch: time.Epoch, mask_rad: f64, power: *const Power) Epoch {
    const t = time.atEpoch(self.geometry.window.input.start, epoch);
    _ = self.geometry.advance(epoch);
    const seconds = @as(f64, @floatFromInt(epoch.ms)) / 1000.0;
    const rx = receiver.at(self.geometry.window.input.trajectory, seconds);
    const before = receiver.at(self.geometry.window.input.trajectory, seconds - observation_model.doppler_half_span_s);
    const after = receiver.at(self.geometry.window.input.trajectory, seconds + observation_model.doppler_half_span_s);
    var count: usize = 0;
    var used: usize = 0;
    var pending: ?struct { index: usize, ready: observation_model.Ready } = null;
    for (self.geometry.entries, 0..) |*track, index| {
        const ready = track.ready() orelse continue;
        if (ready.geometry.columnsAt(t).el_rad < mask_rad) continue;
        if (pending) |first| {
            const pair = observation_model.evalPair(.{ first.ready, ready }, .{ rx, before, after }, t);
            self.project(first.index, first.ready, pair[0], power, &count, &used);
            self.project(index, ready, pair[1], power, &count, &used);
            pending = null;
        } else {
            pending = .{ .index = index, .ready = ready };
        }
    }
    if (pending) |last| {
        self.project(last.index, last.ready, .{
            .center = observation_model.evalSat(last.ready, rx, t),
            .doppler = .of(last.ready, before, after, t),
        }, power, &count, &used);
    }
    self.advanced = epoch;
    return .{ .t = t, .sats = self.satellites[0..count] };
}
