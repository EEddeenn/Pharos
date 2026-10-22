const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const coordinates = @import("domain/earth/coordinates");
const attitude = @import("domain/earth/attitude");
const sun = @import("domain/earth/sun");
const orbit_constants = @import("domain/navigation/orbit/constants");
const clock_reference = @import("domain/navigation/clock_reference");
const physical = @import("domain/physical_constants");

const GpsTime = time.GpsTime;
const ClockReferences = clock_reference.ClockReferences;
const Transmitter = struct { body_m: [3]f64, law: attitude.Law };
const ClockSample = struct { t: GpsTime, bias_s: f64 };

pub const window = 10;
pub const coverage_span_s: f64 = 61;
pub const grid_tolerance_s: f64 = 1e-3;
pub const min_interval_s: f64 = 1e-3;
pub const max_interval_s: f64 = 100_000;
pub const max_clock_s: f64 = 1;

const max_clock_gap_s: f64 = 1800;
const pco_rate_half_s: f64 = 0.5;
const max_slots_per_sample = 4;
const max_radius_m: f64 = 5e7;

pub const OrbitSample = struct {
    sat: gnss_types.SatId,
    t: GpsTime,
    pos: [3]f64,
    clock_s: ?f64,
};

pub const ClockRecord = struct {
    sat: gnss_types.SatId,
    t: GpsTime,
    bias_s: f64,
};

pub const State = struct {
    pos: coordinates.Ecef,
    vel: coordinates.Ecef,
    clock_bias_s: f64,
    clock_drift: f64,
    rel_s: f64,
};

pub const Series = struct {
    sat: gnss_types.SatId,
    t0: GpsTime,
    base: u64 = 0,
    pos: []const ?[3]f64,
    clock: []const ClockSample,
};

pub const BuildError = error{ OutOfMemory, MalformedRecord, EmptyProduct, SparseEpochs };

/// Immutable precise observations and their clock definition. The arena owns every sample and descriptor.
pub const Data = struct {
    series: []const Series,
    interval_s: f64,
    clock_reference: ClockReferences,

    pub fn build(arena: std.mem.Allocator, orbit: []const OrbitSample, interval_s: f64, clocks: []const ClockRecord, refs: ClockReferences) BuildError!Data {
        if (orbit.len == 0) return error.EmptyProduct;
        var index: [256]?u16 = @splat(null);
        var builders: std.ArrayList(SeriesBuilder) = .empty;
        for (orbit) |sample| {
            const found = index[sample.sat.key()];
            const i = found orelse blk: {
                const next: u16 = @intCast(builders.items.len);
                try builders.append(arena, .{ .sat = sample.sat, .first = sample.t, .last = sample.t });
                index[sample.sat.key()] = next;
                break :blk next;
            };
            const builder = &builders.items[i];
            if (sample.t.lessThan(builder.first)) builder.first = sample.t;
            if (builder.last.lessThan(sample.t)) builder.last = sample.t;
            builder.sample_count += 1;
        }
        for (clocks) |sample| if (index[sample.sat.key()]) |i| {
            builders.items[i].external_clock_count += 1;
        };
        for (builders.items) |*builder| {
            const slots = @round(builder.last.secondsSince(builder.first) / interval_s) + 1;
            if (slots > max_slots_per_sample * @as(f64, @floatFromInt(builder.sample_count)) + 2 * window) return error.SparseEpochs;
            builder.positions = try arena.alloc(?[3]f64, @intFromFloat(slots));
            @memset(builder.positions, null);
        }
        for (orbit) |sample| {
            const builder = &builders.items[index[sample.sat.key()].?];
            const k_f = sample.t.secondsSince(builder.first) / interval_s;
            const k = @round(k_f);
            if (@abs(k_f - k) > grid_tolerance_s / interval_s) return error.MalformedRecord;
            builder.positions[@intFromFloat(k)] = sample.pos;
            if (builder.external_clock_count < 2) if (sample.clock_s) |bias_s| {
                try builder.clocks.append(arena, .{ .t = sample.t, .bias_s = bias_s });
            };
        }
        for (clocks) |sample| if (index[sample.sat.key()]) |i| {
            const builder = &builders.items[i];
            if (builder.external_clock_count >= 2) try builder.clocks.append(arena, .{ .t = sample.t, .bias_s = sample.bias_s });
        };
        const series = try arena.alloc(Series, builders.items.len);
        for (builders.items, series) |*builder, *out| {
            std.mem.sort(ClockSample, builder.clocks.items, {}, clockBefore);
            var kept: usize = 0;
            for (builder.clocks.items) |sample| {
                if (kept > 0 and builder.clocks.items[kept - 1].t.eql(sample.t)) kept -= 1;
                builder.clocks.items[kept] = sample;
                kept += 1;
            }
            out.* = .{ .sat = builder.sat, .t0 = builder.first, .pos = builder.positions, .clock = builder.clocks.items[0..kept] };
        }
        return .{ .series = series, .interval_s = interval_s, .clock_reference = refs };
    }

    /// A new descriptor slice over the same immutable samples. Existing views remain valid and keep their original bounds.
    pub fn trimmed(self: Data, arena: std.mem.Allocator, from: GpsTime, until: GpsTime) std.mem.Allocator.Error!Data {
        const series = try arena.dupe(Series, self.series);
        for (series) |*sr| {
            var first: usize = 0;
            while (first < sr.pos.len and sr.t0.addSeconds(@as(f64, @floatFromInt(sr.base + first)) * self.interval_s).lessThan(from)) first += 1;
            var end = sr.pos.len;
            while (end > first and until.lessThan(sr.t0.addSeconds(@as(f64, @floatFromInt(sr.base + end - 1)) * self.interval_s))) end -= 1;
            sr.base += first;
            sr.pos = sr.pos[first..end];

            const clock_from = from.addSeconds(-max_clock_gap_s);
            const clock_until = until.addSeconds(max_clock_gap_s);
            var clock_first: usize = 0;
            while (clock_first < sr.clock.len and sr.clock[clock_first].t.lessThan(clock_from)) clock_first += 1;
            var clock_end = sr.clock.len;
            while (clock_end > clock_first and clock_until.lessThan(sr.clock[clock_end - 1].t)) clock_end -= 1;
            sr.clock = sr.clock[clock_first..clock_end];
        }
        return .{ .series = series, .interval_s = self.interval_s, .clock_reference = self.clock_reference };
    }
};

/// A query index borrowing immutable series. The backing descriptors and samples must outlive every handle.
pub const Product = struct {
    series: []const Series,
    index: [256]?u16,
    interval_s: f64,

    pub fn init(series: []const Series, interval_s: f64) Product {
        var index: [256]?u16 = @splat(null);
        for (series, 0..) |sr, i| index[sr.sat.key()] = @intCast(i);
        return .{ .series = series, .index = index, .interval_s = interval_s };
    }

    pub fn serves(self: *const Product, sat: gnss_types.SatId, from: GpsTime, until: GpsTime) bool {
        const series = self.seriesOf(sat) orelse return false;
        return servesSeries(series, self.interval_s, from, until);
    }

    pub fn handle(self: *const Product, sat: gnss_types.SatId, from: GpsTime, until: GpsTime, tx: ?Transmitter) ?Handle {
        const series = self.seriesOf(sat) orelse return null;
        if (!servesSeries(series, self.interval_s, from, until)) return null;
        return .{ .series = series, .interval_s = self.interval_s, .span = .{ .from = from, .until = until }, .tx = tx };
    }

    fn seriesOf(self: *const Product, sat: gnss_types.SatId) ?*const Series {
        return &self.series[self.index[sat.key()] orelse return null];
    }
};

/// A covered interval of one immutable series. It does not borrow the Product index.
pub const Handle = struct {
    series: *const Series,
    interval_s: f64,
    span: struct { from: GpsTime, until: GpsTime },
    tx: ?Transmitter,

    pub fn state(self: Handle, t: GpsTime) State {
        std.debug.assert(!t.lessThan(self.span.from) and !self.span.until.lessThan(t));
        const o = orbitAt(self.series, self.interval_s, t);
        const c = clockAt(self.series, t);
        var pos: coordinates.Ecef = .fromArray(o.pos);
        var vel: coordinates.Ecef = .fromArray(o.vel);
        if (self.tx) |transmitter| {
            const omega_e = orbit_constants.get(self.series.sat.system).omega_e;
            const off = phaseCentreOffset(pos, vel, omega_e, t, transmitter);
            const before = orbitAt(self.series, self.interval_s, t.addSeconds(-pco_rate_half_s));
            const after = orbitAt(self.series, self.interval_s, t.addSeconds(pco_rate_half_s));
            const off_a = phaseCentreOffset(.fromArray(before.pos), .fromArray(before.vel), omega_e, t.addSeconds(-pco_rate_half_s), transmitter);
            const off_b = phaseCentreOffset(.fromArray(after.pos), .fromArray(after.vel), omega_e, t.addSeconds(pco_rate_half_s), transmitter);
            pos = pos.add(off);
            vel = vel.add(off_b.sub(off_a).scale(1 / (2 * pco_rate_half_s)));
        }
        return .{
            .pos = pos,
            .vel = vel,
            .clock_bias_s = c.bias_s,
            .clock_drift = c.drift,
            .rel_s = -2.0 * coordinates.Ecef.fromArray(o.pos).dot(.fromArray(o.vel)) / (physical.light_speed * physical.light_speed),
        };
    }
};

const SeriesBuilder = struct {
    sat: gnss_types.SatId,
    first: GpsTime,
    last: GpsTime,
    sample_count: usize = 0,
    external_clock_count: usize = 0,
    positions: []?[3]f64 = &.{},
    clocks: std.ArrayList(ClockSample) = .empty,
};

const Orbit = struct { pos: [3]f64, vel: [3]f64 };

const Clock = struct { bias_s: f64, drift: f64 };

pub fn positionInRange(pos: [3]f64) bool {
    return coordinates.Ecef.fromArray(pos).norm() <= max_radius_m;
}

fn clockBefore(_: void, a: ClockSample, b: ClockSample) bool {
    return a.t.lessThan(b.t);
}

fn servesSeries(series: *const Series, interval_s: f64, from: GpsTime, until: GpsTime) bool {
    return orbitComplete(series, interval_s, from.addSeconds(-pco_rate_half_s), until.addSeconds(pco_rate_half_s)) and clockBridged(series, from, until);
}

fn phaseCentreOffset(pos: coordinates.Ecef, vel: coordinates.Ecef, omega_e: f64, t: GpsTime, tx: Transmitter) coordinates.Ecef {
    const axes = attitude.BodyAxes.of(tx.law, pos, vel, omega_e, sun.positionEcef(t)) orelse return .{ .x = 0, .y = 0, .z = 0 };
    return axes.toEcef(tx.body_m);
}

fn windowStart(sr: *const Series, interval_s: f64, t: GpsTime) ?usize {
    if (sr.pos.len < window + 1) return null;
    const x = t.secondsSince(sr.t0) / interval_s - @as(f64, @floatFromInt(sr.base));
    const first = @floor(x) - (window / 2 - 1);
    if (!(first >= 0 and first <= @as(f64, @floatFromInt(sr.pos.len - (window + 1))))) return null;
    return @intFromFloat(first);
}

fn lagrange(sr: *const Series, interval_s: f64, first: usize, x: f64) Orbit {
    var y: [window][3]f64 = undefined;
    for (0..window) |j| y[j] = sr.pos[first + j].?;
    const u = x - @as(f64, @floatFromInt(first));
    var pos: [3]f64 = .{ 0, 0, 0 };
    var vel: [3]f64 = .{ 0, 0, 0 };
    for (0..window) |j| {
        const xj: f64 = @floatFromInt(j);
        var l: f64 = 1;
        var dl: f64 = 0;
        for (0..window) |m| {
            if (m == j) continue;
            const xm: f64 = @floatFromInt(m);
            const num = u - xm;
            const den = xj - xm;
            dl = dl * num / den + l / den;
            l = l * num / den;
        }
        for (0..3) |c| {
            pos[c] += l * y[j][c];
            vel[c] += dl / interval_s * y[j][c];
        }
    }
    return .{ .pos = pos, .vel = vel };
}

fn orbitAt(sr: *const Series, interval_s: f64, t: GpsTime) Orbit {
    const x = t.secondsSince(sr.t0) / interval_s - @as(f64, @floatFromInt(sr.base));
    const first: usize = @intFromFloat(@floor(x) - (window / 2 - 1));
    const a = lagrange(sr, interval_s, first, x);
    const b = lagrange(sr, interval_s, first + 1, x);
    const w = x - @floor(x);
    var out: Orbit = undefined;
    for (0..3) |c| {
        out.pos[c] = (1.0 - w) * a.pos[c] + w * b.pos[c];
        out.vel[c] = (1.0 - w) * a.vel[c] + w * b.vel[c] + (b.pos[c] - a.pos[c]) / interval_s;
    }
    return out;
}

fn notAfter(t: GpsTime, s: ClockSample) bool {
    return !t.lessThan(s.t);
}

fn clockPair(c: []const ClockSample, t: GpsTime) ?usize {
    if (c.len < 2) return null;
    const after = std.sort.partitionPoint(ClockSample, c, t, notAfter);
    if (after == 0) return null;
    var i = after - 1;
    if (i + 1 >= c.len) {
        if (!c[i].t.eql(t)) return null;
        i -= 1;
    }
    return i;
}

/// Two samples closer than the epochs' tolerance are one epoch: no drift is told between them.
fn bridged(span_s: f64) bool {
    return span_s >= grid_tolerance_s and span_s <= max_clock_gap_s;
}

fn clockAt(sr: *const Series, t: GpsTime) Clock {
    const c = sr.clock;
    const after = std.sort.partitionPoint(ClockSample, c, t, notAfter);
    const i = if (after == c.len) c.len - 2 else after - 1;
    const a = c[i];
    const b = c[i + 1];
    const span = b.t.secondsSince(a.t);
    const drift = (b.bias_s - a.bias_s) / span;
    return .{ .bias_s = a.bias_s + drift * t.secondsSince(a.t), .drift = drift };
}

fn clockBridged(sr: *const Series, from: GpsTime, until: GpsTime) bool {
    const c = sr.clock;
    var i = clockPair(c, from) orelse return false;
    const last = clockPair(c, until) orelse return false;
    while (i <= last) : (i += 1) if (!bridged(c[i + 1].t.secondsSince(c[i].t))) return false;
    return true;
}

fn orbitComplete(sr: *const Series, interval_s: f64, from: GpsTime, to: GpsTime) bool {
    const a = windowStart(sr, interval_s, from) orelse return false;
    const b = windowStart(sr, interval_s, to) orelse return false;
    for (a..b + window + 1) |k| if (sr.pos[k] == null) return false;
    return true;
}
