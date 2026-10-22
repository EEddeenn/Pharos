const std = @import("std");
const windows = @import("simulation/geometry/window");
const tropo = @import("domain/propagation/troposphere/model");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const coordinates = @import("domain/earth/coordinates");
const sun = @import("domain/earth/sun");
const attitude = @import("domain/earth/attitude");
const orbit_constants = @import("domain/navigation/orbit/constants");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const signal_catalog = @import("domain/signals/catalog");
const lighttime = @import("domain/propagation/light_time");
const provider = @import("simulation/tracking/track");
const geometry = @import("simulation/geometry/geometry");
const receiver = @import("simulation/geometry/receiver");
const physical = @import("domain/physical_constants");
const earth_constants = @import("domain/earth/constants");

const Payload = @import("domain/signals/payload").Payload;

const GpsTime = time.GpsTime;
const Epoch = time.Epoch;
const Window = windows.Window;

const Corrections = Correction(f64);

const Endpoint = struct {
    site: tropo.Site,
    models: ionosphere_model.PreparedModels,
    sun: coordinates.Ecef,
};

pub const Entry = struct {
    sat: gnss_types.SatId,
    geometry: ?geometry.Ready = null,
    corrections: [2]Corrections = undefined,
    delays: provider.DelaySnapshot = undefined,

    pub fn ready(self: *const Entry) ?Ready {
        return .{ .geometry = self.geometry orelse return null, .corrections = &self.corrections, .delays = &self.delays };
    }
};

pub const Ready = struct {
    geometry: geometry.Ready,
    corrections: *const [2]Corrections,
    delays: *const provider.DelaySnapshot,

    pub fn delaysAt(self: Ready, t: GpsTime) provider.Delays {
        return self.delays.at(t);
    }

    pub fn columnsAt(self: Ready, t: GpsTime) Columns(f64) {
        const k = self.geometry.knots;
        const f = geometry.Interpolation(f64, GpsTime).fraction(&k[0], &k[1], t);
        return interpolateCorrections(f64, &self.corrections[0], &self.corrections[1], f, self.geometry.columnsAt(t));
    }
};

pub const Observation = struct {
    window: Window,
    models: *const ionosphere_model.Models,
    preparer: ionosphere_model.Preparer = .{},
    ends: [2]Endpoint = undefined,
    entries: []Entry,

    pub fn init(gpa: std.mem.Allocator, input: windows.Inputs, signals: std.EnumSet(gnss_types.Signal), payload: *const Payload, models: *const ionosphere_model.Models, mask_out: std.EnumArray(gnss_types.System, gnss_types.SatSet)) std.mem.Allocator.Error!Observation {
        var window = try Window.init(gpa, input, signals, payload, mask_out);
        errdefer window.deinit(gpa);
        const entries = try gpa.alloc(Entry, window.tracks.len);
        for (window.tracks, entries) |tr, *entry| entry.* = .{ .sat = tr.sat };
        return .{ .window = window, .models = models, .entries = entries };
    }

    pub fn deinit(self: *Observation, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        self.window.deinit(gpa);
    }

    pub fn reset(self: *Observation) void {
        self.window.reset();
        for (self.entries) |*entry| entry.geometry = null;
    }

    pub fn mark(self: *const Observation, out: []provider.Mark) void {
        self.window.mark(out);
    }

    pub fn restore(self: *Observation, marks: []const provider.Mark) void {
        self.window.restore(marks);
        for (self.entries) |*entry| entry.geometry = null;
    }

    pub fn base(self: *const Observation) Epoch {
        return self.window.base();
    }

    pub fn advance(self: *Observation, epoch: Epoch) std.EnumArray(gnss_types.System, gnss_types.SatSet) {
        const switched = self.begin(epoch);
        for (0..self.entries.len) |i| self.correct(i);
        return switched;
    }

    // The window's step and the second's ends; correct then makes each track's corrections, in any order and on any
    // thread.
    pub fn begin(self: *Observation, epoch: Epoch) std.EnumArray(gnss_types.System, gnss_types.SatSet) {
        const switched = self.window.advance(epoch);
        const t = time.atEpoch(self.window.input.start, self.window.base());
        switch (self.window.move) {
            .kept => {},
            .shifted => {
                self.ends[0] = self.ends[1];
                self.prepare(t.addSeconds(1.0), self.window.ends[1], &self.ends[1]);
            },
            .begun => {
                self.prepare(t, self.window.ends[0], &self.ends[0]);
                self.prepare(t.addSeconds(1.0), self.window.ends[1], &self.ends[1]);
            },
        }
        for (self.window.tracks, self.entries) |*tr, *entry| {
            entry.geometry = tr.ready();
            if (entry.geometry != null and tr.move == .begun) entry.delays = tr.ephemeris.delaySnapshot();
        }
        return switched;
    }

    pub fn moved(self: *const Observation) bool {
        for (self.window.tracks, self.entries) |*tr, *entry| if (entry.geometry != null and tr.move != .kept) return true;
        return false;
    }

    pub fn correct(self: *Observation, i: usize) void {
        const tr = &self.window.tracks[i];
        const entry = &self.entries[i];
        const ready = entry.geometry orelse return;
        switch (tr.move) {
            .kept => {},
            .shifted => {
                entry.corrections[0] = entry.corrections[1];
                entry.corrections[1] = corrections(tr, &ready.knots[1], self.window.ends[1], &self.ends[1]);
            },
            .begun => entry.corrections = .{
                corrections(tr, &ready.knots[0], self.window.ends[0], &self.ends[0]),
                corrections(tr, &ready.knots[1], self.window.ends[1], &self.ends[1]),
            },
        }
    }

    fn prepare(self: *Observation, t: GpsTime, rx: receiver.Frame, out: *Endpoint) void {
        out.site = tropo.site(t, rx.lla);
        out.sun = sun.positionEcef(t);
        self.preparer.at(self.models, t, rx.lla, &out.models);
    }
};

pub const SatEpoch = EpochValue(f64, GpsTime);

pub const Sample = struct { center: SatEpoch, doppler: DopplerPair };

pub const doppler_half_span_s: f64 = 0.0005;
const doppler_span_s: f64 = 0.001;

pub const DopplerPair = struct {
    a: SatEpoch,
    b: SatEpoch,
    da: provider.Delays,
    db: provider.Delays,

    pub fn of(track: Ready, before: receiver.Frame, after: receiver.Frame, t_rx: GpsTime) DopplerPair {
        const t_a = t_rx.addSeconds(-doppler_half_span_s);
        const t_b = t_rx.addSeconds(doppler_half_span_s);
        return .{
            .a = evalSat(track, before, t_a),
            .b = evalSat(track, after, t_b),
            .da = track.delaysAt(t_a),
            .db = track.delaysAt(t_b),
        };
    }

    pub fn hz(self: *const DopplerPair, signal: gnss_types.Signal, freq: ?gnss_types.FreqId) f64 {
        const a = channelPhase(self.a, signal, freq, self.da.carrier(signal));
        const b = channelPhase(self.b, signal, freq, self.db.carrier(signal));
        return -(b - a) / doppler_span_s;
    }
};

pub fn evalSat(track: Ready, rx: receiver.Frame, t_rx: GpsTime) SatEpoch {
    return evaluateSat(f64, GpsTime, &track, rx.pos, rx.radius_m, t_rx);
}

pub fn evalPair(ready: [2]Ready, receivers: [3]receiver.Frame, t: GpsTime) [2]Sample {
    const packet = Packet(2).gather(ready);
    const t_a = t.addSeconds(-doppler_half_span_s);
    const t_b = t.addSeconds(doppler_half_span_s);
    const center = packet.evaluate(receivers[0], t);
    const before = packet.evaluate(receivers[1], t_a);
    const after = packet.evaluate(receivers[2], t_b);
    var out: [2]Sample = undefined;
    inline for (0..2) |i| out[i] = .{
        .center = Packet(2).lane(center, i),
        .doppler = .{
            .a = Packet(2).lane(before, i),
            .b = Packet(2).lane(after, i),
            .da = ready[i].delaysAt(t_a),
            .db = ready[i].delaysAt(t_b),
        },
    };
    return out;
}

pub fn channelTravel(s: SatEpoch, signal: gnss_types.Signal, freq: ?gnss_types.FreqId, group_delay_s: f64) f64 {
    return s.travel_s + s.pco_m[signal_catalog.slot(signal)] / physical.light_speed + group_delay_s + s.iono_l1_m * signal_catalog.get(signal).ionoFactor(freq) / physical.light_speed;
}

pub fn channelPhase(s: SatEpoch, signal: gnss_types.Signal, freq: ?gnss_types.FreqId, group_delay_s: f64) f64 {
    const row = signal_catalog.get(signal);
    const metres = s.range_m + s.shapiro_m + s.pco_m[signal_catalog.slot(signal)] - physical.light_speed * s.clock_s + physical.light_speed * group_delay_s + s.tropo_m - s.iono_l1_m * row.ionoFactor(freq);
    return metres / row.wavelengthM(freq);
}

pub fn transmitTime(s: SatEpoch, signal: gnss_types.Signal, freq: ?gnss_types.FreqId, group_delay_s: f64) GpsTime {
    return s.t_rx.minusSeconds(channelTravel(s, signal, freq, group_delay_s));
}

fn Correction(comptime Number: type) type {
    return struct {
        iono_l1_m: Number,
        tropo_m: Number,
        pco_m: [signal_catalog.max_per_system]Number,
    };
}

fn Columns(comptime Number: type) type {
    return struct {
        iono_l1_m: Number,
        tropo_m: Number,
        el_rad: Number,
        az_rad: Number,
        pco_m: [signal_catalog.max_per_system]Number,
    };
}

fn interpolateCorrections(comptime Number: type, a: *const Correction(Number), b: *const Correction(Number), f: Number, angles: anytype) Columns(Number) {
    var pco_m: [signal_catalog.max_per_system]Number = undefined;
    for (&pco_m, a.pco_m, b.pco_m) |*m, left, right| m.* = left + (right - left) * f;
    return .{
        .iono_l1_m = a.iono_l1_m + (b.iono_l1_m - a.iono_l1_m) * f,
        .tropo_m = a.tropo_m + (b.tropo_m - a.tropo_m) * f,
        .el_rad = angles.el_rad,
        .az_rad = angles.az_rad,
        .pco_m = pco_m,
    };
}

fn corrections(tr: *const windows.Track, k: *const geometry.Knot, rx: receiver.Frame, endpoint: *const Endpoint) Corrections {
    var pco_m: [signal_catalog.max_per_system]f64 = @splat(0);
    if (tr.ephemeris.phaseCentre()) |centre| {
        const lt = k.lt;
        // A satellite with no orbit plane has no attitude to place its phase centre by: none is applied.
        if (attitude.BodyAxes.of(centre.law, rx.pos.add(lt.los.scale(lt.range_m)), lt.sat_vel, orbit_constants.get(tr.sat.system).omega_e, endpoint.sun)) |frame| {
            const along: [3]f64 = .{ frame.x.dot(lt.los), frame.y.dot(lt.los), frame.z.dot(lt.los) };
            for (&pco_m, centre.offset_m) |*m, off| m.* = off[0] * along[0] + off[1] * along[1] + off[2] * along[2];
        }
    }
    return .{
        .iono_l1_m = endpoint.models.get(tr.sat.system).delayL1(k.state.pos, k.el_rad, k.az_rad),
        .tropo_m = tropo.delay(endpoint.site, k.el_rad),
        .pco_m = pco_m,
    };
}

fn EpochValue(comptime Number: type, comptime Time: type) type {
    return struct {
        t_rx: Time,
        range_m: Number,
        clock_s: Number,
        iono_l1_m: Number,
        tropo_m: Number,
        shapiro_m: Number,
        pco_m: [signal_catalog.max_per_system]Number,
        el_rad: Number,
        az_rad: Number,
        travel_s: Number,
    };
}

fn evaluateSat(comptime Number: type, comptime Time: type, track: anytype, rx_pos: coordinates.Cartesian(Number), rx_radius: Number, t_rx: Time) EpochValue(Number, Time) {
    const c: Number = if (Number == f64) physical.light_speed else @splat(physical.light_speed);
    const source = &track.geometry;
    const lt = lighttime.Solver(Number, Time).solve(source, rx_pos, t_rx, source.omegaEarth(), source.stateAt(t_rx).pos);
    const slow = track.columnsAt(t_rx);
    const clock_s = source.clockBiasAt(lt.t_tx) + source.relAt(lt.t_tx);
    const shapiro_m = shapiro(Number, rx_radius, rx_pos.add(lt.los.scale(lt.range_m)).norm(), lt.range_m);
    return .{
        .t_rx = t_rx,
        .range_m = lt.range_m,
        .clock_s = clock_s,
        .iono_l1_m = slow.iono_l1_m,
        .tropo_m = slow.tropo_m,
        .shapiro_m = shapiro_m,
        .pco_m = slow.pco_m,
        .el_rad = slow.el_rad,
        .az_rad = slow.az_rad,
        .travel_s = (lt.range_m + shapiro_m) / c - clock_s + slow.tropo_m / c,
    };
}

fn shapiro(comptime Number: type, r_rx: Number, r_sat: Number, range_m: Number) Number {
    const factor = 2.0 * earth_constants.earth_gm / (physical.light_speed * physical.light_speed);
    const scale: Number = if (Number == f64) factor else @splat(factor);
    const sum = r_sat + r_rx;
    return scale * @log((sum + range_m) / (sum - range_m));
}

fn Packet(comptime width: usize) type {
    return struct {
        geometry: Geometry,
        corrections: [2]Correction(Vector),

        const Self = @This();
        const Vector = @Vector(width, f64);
        const Time = time.Batch(width);
        const Point = coordinates.Cartesian(Vector);
        const Interpolation = geometry.Interpolation(Vector, Time);
        const Value = EpochValue(Vector, Time);

        const Knot = struct {
            t: Time,
            state: struct {
                pos: Point,
                vel: Point,
                clock_bias_s: Vector,
                clock_drift: Vector,
                rel_s: Vector,
            },
            el_rad: Vector,
            az_rad: Vector,
        };

        const Geometry = struct {
            knots: [2]Knot,
            omega_e: Vector,

            pub fn stateAt(self: *const Geometry, t: Time) lighttime.Solver(Vector, Time).Sample {
                return Interpolation.stateAt(&self.knots[0], &self.knots[1], t);
            }

            pub fn clockBiasAt(self: *const Geometry, t: Time) Vector {
                return Interpolation.clockBiasAt(&self.knots[0], &self.knots[1], t);
            }

            pub fn relAt(self: *const Geometry, t: Time) Vector {
                return Interpolation.relAt(&self.knots[0], &self.knots[1], t);
            }

            pub fn columnsAt(self: *const Geometry, t: Time) @TypeOf(Interpolation.columnsAt(&self.knots[0], &self.knots[1], t)) {
                return Interpolation.columnsAt(&self.knots[0], &self.knots[1], t);
            }

            pub fn omegaEarth(self: *const Geometry) Vector {
                return self.omega_e;
            }
        };

        pub fn columnsAt(self: *const Self, t: Time) Columns(Vector) {
            const k = &self.geometry.knots;
            const f = Interpolation.fraction(&k[0], &k[1], t);
            return interpolateCorrections(Vector, &self.corrections[0], &self.corrections[1], f, self.geometry.columnsAt(t));
        }

        fn gather(ready: [width]Ready) Self {
            var out: Self = undefined;
            inline for (0..width) |i| {
                out.geometry.omega_e[i] = ready[i].geometry.omegaEarth();
                inline for (0..2) |end| {
                    const k = &ready[i].geometry.knots[end];
                    const target = &out.geometry.knots[end];
                    target.t.values[i] = k.t;
                    inline for (.{ "x", "y", "z" }) |axis| {
                        @field(target.state.pos, axis)[i] = @field(k.state.pos, axis);
                        @field(target.state.vel, axis)[i] = @field(k.state.vel, axis);
                    }
                    target.state.clock_bias_s[i] = k.state.clock_bias_s;
                    target.state.clock_drift[i] = k.state.clock_drift;
                    target.state.rel_s[i] = k.state.rel_s;
                    target.el_rad[i] = k.el_rad;
                    target.az_rad[i] = k.az_rad;
                    const c = &ready[i].corrections[end];
                    out.corrections[end].iono_l1_m[i] = c.iono_l1_m;
                    out.corrections[end].tropo_m[i] = c.tropo_m;
                    inline for (0..signal_catalog.max_per_system) |slot| out.corrections[end].pco_m[slot][i] = c.pco_m[slot];
                }
            }
            return out;
        }

        fn evaluate(self: *const Self, rx: receiver.Frame, t: GpsTime) Value {
            const pos: Point = .{ .x = @splat(rx.pos.x), .y = @splat(rx.pos.y), .z = @splat(rx.pos.z) };
            return evaluateSat(Vector, Time, self, pos, @splat(rx.radius_m), .splat(t));
        }

        fn lane(value: Value, comptime i: usize) SatEpoch {
            var pco_m: [signal_catalog.max_per_system]f64 = undefined;
            inline for (0..signal_catalog.max_per_system) |slot| pco_m[slot] = value.pco_m[slot][i];
            return .{
                .t_rx = value.t_rx.values[i],
                .range_m = value.range_m[i],
                .clock_s = value.clock_s[i],
                .iono_l1_m = value.iono_l1_m[i],
                .tropo_m = value.tropo_m[i],
                .shapiro_m = value.shapiro_m[i],
                .pco_m = pco_m,
                .el_rad = value.el_rad[i],
                .az_rad = value.az_rad[i],
                .travel_s = value.travel_s[i],
            };
        }
    };
}
