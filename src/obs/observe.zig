const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const geo = shared.geo;
const types = core.types;
const Power = shared.stage.power.Power;
const Ionosphere = shared.stage.ionosphere.Ionosphere;

pub const Signal = struct {
    signal: types.Signal,
    pseudorange_m: [gnss.spec.max_observables]f64,
    phase_cycles: f64,
    doppler_hz: f64,
    cn0_dbhz: f64,
};

pub const Satellite = struct { sat: types.SatId, signals: []const Signal };
pub const Epoch = struct { t: core.time.GpsTime, sats: []const Satellite };

const Span = struct { first: usize, end: usize };

pub const Evaluator = struct {
    gpa: std.mem.Allocator,
    bundle: *const shared.bundle.Bundle,
    allocation: gnss.allocation.Allocation,
    ionosphere: Ionosphere,
    geometry: geo.Observation,
    spans: []Span,
    signals: []types.Signal,
    satellites: []Satellite,
    values: []Signal,

    pub fn create(gpa: std.mem.Allocator, b: *const shared.bundle.Bundle) error{OutOfMemory}!*Evaluator {
        const self = try gpa.create(Evaluator);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .bundle = b,
            .allocation = gnss.allocation.at(b.scenario.start),
            .ionosphere = try Ionosphere.create(gpa, &b.scenario.ionosphere.ready, b.scenario.signals),
            .geometry = undefined,
            .spans = &.{},
            .signals = &.{},
            .satellites = &.{},
            .values = &.{},
        };
        errdefer self.ionosphere.deinit(gpa);
        self.geometry = try geo.Observation.init(gpa, b, &self.allocation, &self.ionosphere.models, b.scenario.mask_out);
        errdefer self.geometry.deinit(gpa);
        const tracks = self.geometry.frame().tracks;
        self.spans = try gpa.alloc(Span, tracks.len);
        errdefer gpa.free(self.spans);
        var count: usize = 0;
        for (tracks, self.spans) |track, *span| {
            span.first = count;
            for (std.meta.tags(types.Signal)) |signal| {
                if (b.scenario.signals.contains(signal) and self.allocation.transmits(track.sat, signal)) count += 1;
            }
            span.end = count;
        }
        self.signals = try gpa.alloc(types.Signal, count);
        errdefer gpa.free(self.signals);
        for (tracks, self.spans) |track, span| {
            var next = span.first;
            for (std.meta.tags(types.Signal)) |signal| {
                if (!b.scenario.signals.contains(signal) or !self.allocation.transmits(track.sat, signal)) continue;
                self.signals[next] = signal;
                next += 1;
            }
        }
        self.satellites = try gpa.alloc(Satellite, tracks.len);
        errdefer gpa.free(self.satellites);
        self.values = try gpa.alloc(Signal, count);
        return self;
    }

    pub fn destroy(self: *Evaluator) void {
        const gpa = self.gpa;
        gpa.free(self.values);
        gpa.free(self.satellites);
        gpa.free(self.signals);
        gpa.free(self.spans);
        self.geometry.deinit(gpa);
        self.ionosphere.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn tracked(self: *const Evaluator) usize {
        return self.spans.len;
    }

    pub fn evaluate(self: *Evaluator, epoch: core.time.Epoch, mask_rad: f64, power: *const Power) Epoch {
        const t = core.time.atEpoch(self.bundle.scenario.start, epoch);
        _ = self.geometry.advance(epoch);
        const seconds = @as(f64, @floatFromInt(epoch.ms)) / 1000.0;
        const rx = geo.receiver.at(&self.bundle.trajectory, seconds);
        const before = geo.receiver.at(&self.bundle.trajectory, seconds - geo.observation.doppler_half_span_s);
        const after = geo.receiver.at(&self.bundle.trajectory, seconds + geo.observation.doppler_half_span_s);
        var count: usize = 0;
        var used: usize = 0;
        var pending: ?struct { index: usize, ready: geo.observation.Ready } = null;
        for (self.geometry.frame().tracks, 0..) |*track, index| {
            const ready = track.ready() orelse continue;
            if (ready.geometry.columnsAt(t).el_rad < mask_rad) continue;
            if (pending) |first| {
                const pair = geo.observation.evalPair(.{ first.ready, ready }, .{ rx, before, after }, t);
                self.satellites[count] = self.project(first.index, first.ready, pair[0], power, &used);
                self.satellites[count + 1] = self.project(index, ready, pair[1], power, &used);
                count += 2;
                pending = null;
            } else {
                pending = .{ .index = index, .ready = ready };
            }
        }
        if (pending) |last| {
            self.satellites[count] = self.project(last.index, last.ready, .{
                .center = geo.observation.evalSat(last.ready, rx, t),
                .doppler = .of(last.ready, before, after, t),
            }, power, &used);
            count += 1;
        }
        return .{ .t = t, .sats = self.satellites[0..count] };
    }

    fn project(self: *Evaluator, index: usize, ready: geo.observation.Ready, sample: geo.observation.Sample, power: *const Power, used: *usize) Satellite {
        const sat = sample.center;
        const sat_id = self.geometry.frame().tracks[index].sat;
        const span = self.spans[index];
        const delays = ready.delaysAt(sat.t_rx);
        const freq = delays.record.freq();
        const cn0_dbhz = power.cn0(sat_id, sat.el_rad);
        const first = used.*;
        for (self.signals[span.first..span.end]) |signal| {
            if (!delays.record.serves(signal)) continue;
            var pseudorange_m: [gnss.spec.max_observables]f64 = @splat(0);
            for (gnss.spec.get(signal).observables, 0..) |observable, i| {
                pseudorange_m[i] = geo.observation.channelTravel(sat, signal, freq, delays.code(signal, observable.component)) * core.constants.light_speed;
            }
            self.values[used.*] = .{
                .signal = signal,
                .pseudorange_m = pseudorange_m,
                .phase_cycles = geo.observation.channelPhase(sat, signal, freq, delays.carrier(signal)),
                .doppler_hz = sample.doppler.hz(signal, freq),
                .cn0_dbhz = cn0_dbhz + gnss.spec.realizedDb(signal),
            };
            used.* += 1;
        }
        return .{ .sat = sat_id, .signals = self.values[first..used.*] };
    }
};
