const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const constants = core.constants;
const coord = core.coord;

const ClockRef = gnss.delay.ClockRef;

const Transmitter = struct { body_m: [3]f64, law: core.attitude.Law };

pub const window = 10;
const max_clock_gap_s: f64 = 1800;
pub const coverage_span_s: f64 = 61;
const pco_rate_half_s: f64 = 0.5;
pub const grid_tolerance_s = 1e-3;

const ClockSample = struct { t: GpsTime, bias_s: f64 };

pub const OrbitSample = struct {
    sat: types.SatId,
    t: GpsTime,
    pos: [3]f64,
    clock_s: ?f64,
};

pub const ClockRecord = struct {
    sat: types.SatId,
    t: GpsTime,
    bias_s: f64,
};

pub const State = struct {
    pos: coord.Ecef,
    vel: coord.Ecef,
    clock_bias_s: f64,
    clock_drift: f64,
    rel_s: f64,
};

const Series = struct {
    sat: types.SatId,
    t0: GpsTime,
    base: u64 = 0,
    pos: []?[3]f64,
    clock: []ClockSample,
};

pub const Error = error{ OutOfMemory, MalformedRecord, EmptyProduct, SparseEpochs };

const max_slots_per_sample = 4;

pub const min_interval_s: f64 = 1e-3;
pub const max_interval_s: f64 = 100_000;
const max_radius_m: f64 = 5e7;
pub const max_clock_s: f64 = 1;
const max_epoch_ms: i64 = 1 << 46;

pub fn positionInRange(pos: [3]f64) bool {
    return coord.Ecef.fromArray(pos).norm() <= max_radius_m;
}

pub const Product = struct {
    series: []Series,
    index: [256]?u16,
    interval_s: f64,
    clock_ref: std.EnumArray(types.System, ClockRef),

    pub fn build(arena: std.mem.Allocator, orbit: []const OrbitSample, interval_s: f64, clocks: []const ClockRecord, clock_ref: std.EnumArray(types.System, ClockRef)) Error!Product {
        if (orbit.len == 0) return error.EmptyProduct;
        var index: [256]?u16 = @splat(null);
        var count: u16 = 0;
        for (orbit) |s| {
            if (index[s.sat.key()] == null) {
                index[s.sat.key()] = count;
                count += 1;
            }
        }

        const series = try arena.alloc(Series, count);
        const first = try arena.alloc(GpsTime, count);
        const last = try arena.alloc(GpsTime, count);
        const seen = try arena.alloc(bool, count);
        @memset(seen, false);
        const sample_counts = try arena.alloc(usize, count);
        @memset(sample_counts, 0);
        for (orbit) |s| {
            const i = index[s.sat.key()].?;
            if (!seen[i] or s.t.lessThan(first[i])) first[i] = s.t;
            if (!seen[i] or last[i].lessThan(s.t)) last[i] = s.t;
            seen[i] = true;
            sample_counts[i] += 1;
        }

        for (series, 0..) |*sr, i| {
            const slots = @round(last[i].secondsSince(first[i]) / interval_s) + 1;
            if (slots > max_slots_per_sample * @as(f64, @floatFromInt(sample_counts[i])) + 2 * window) return error.SparseEpochs;
            const n: usize = @intFromFloat(slots);
            const pos = try arena.alloc(?[3]f64, n);
            @memset(pos, null);
            sr.* = .{ .sat = undefined, .t0 = first[i], .pos = pos, .clock = &.{} };
        }

        for (orbit) |s| {
            const sr = &series[index[s.sat.key()].?];
            sr.sat = s.sat;
            const k_f = s.t.secondsSince(sr.t0) / interval_s;
            const k = @round(k_f);
            if (@abs(k_f - k) > grid_tolerance_s / interval_s) return error.MalformedRecord;
            sr.pos[@intFromFloat(k)] = s.pos;
        }

        const clock_counts = try arena.alloc(usize, count);
        @memset(clock_counts, 0);
        for (clocks) |c| if (index[c.sat.key()]) |i| {
            clock_counts[i] += 1;
        };

        for (series, 0..) |*sr, i| {
            var list: std.ArrayList(ClockSample) = .empty;
            if (clock_counts[i] >= 2) {
                for (clocks) |c| if (c.sat == sr.sat) try list.append(arena, .{ .t = c.t, .bias_s = c.bias_s });
            } else {
                for (orbit) |s| {
                    if (s.sat != sr.sat) continue;
                    const bias_s = s.clock_s orelse continue;
                    try list.append(arena, .{ .t = s.t, .bias_s = bias_s });
                }
            }
            std.mem.sort(ClockSample, list.items, {}, clockBefore);

            var kept: usize = 0;
            for (list.items) |c| {
                if (kept > 0 and list.items[kept - 1].t.eql(c.t)) kept -= 1;
                list.items[kept] = c;
                kept += 1;
            }
            sr.clock = list.items[0..kept];
        }
        return .{ .series = series, .index = index, .interval_s = interval_s, .clock_ref = clock_ref };
    }

    fn clockBefore(_: void, a: ClockSample, b: ClockSample) bool {
        return a.t.lessThan(b.t);
    }

    fn seriesOf(self: *const Product, sat: types.SatId) ?*const Series {
        const i = self.index[sat.key()] orelse return null;
        return &self.series[i];
    }

    pub fn satelliteCount(self: *const Product) usize {
        return self.series.len;
    }

    pub fn validate(self: *const Product) ?[]const u8 {
        if (!intervalInRange(self.interval_s)) return "the product's epoch interval is outside its range";

        var indexed: usize = 0;
        for (self.index, 0..) |entry, key| if (entry) |i| {
            if (i >= self.series.len) return "the product's index points past its series";
            if (self.series[i].sat.key() != key) return "the product's index points to another satellite's series";
            indexed += 1;
        };
        if (indexed != self.series.len) return "the product's index does not name every series";

        for (self.series) |sr| {
            if (!sr.sat.valid()) return "a product series names a satellite outside its system";
            if (!epochInRange(sr.t0) or sr.base > max_epoch_ms or sr.pos.len > max_epoch_ms) {
                return "a product series' first epoch or length is outside its range";
            }
            for (sr.pos) |p| {
                const pos = p orelse continue;
                if (!positionInRange(pos)) return "a product position is outside its range";
            }
            for (sr.clock, 0..) |c, i| {
                if (!epochInRange(c.t)) return "a product clock epoch is outside its range";
                if (!(@abs(c.bias_s) <= max_clock_s)) return "a product clock bias is outside its range";
                if (i > 0 and c.t.lessThan(sr.clock[i - 1].t)) return "the clock samples of a product series are not in order";
            }
        }
        return null;
    }

    pub fn serves(self: *const Product, sat: types.SatId, from: GpsTime, until: GpsTime) bool {
        const sr = self.seriesOf(sat) orelse return false;
        return orbitComplete(sr, self.interval_s, from.addSeconds(-pco_rate_half_s), until.addSeconds(pco_rate_half_s)) and
            clockBridged(sr, from, until);
    }

    pub fn handle(self: *const Product, sat: types.SatId, from: GpsTime, until: GpsTime, tx: ?Transmitter) ?Handle {
        if (!self.serves(sat, from, until)) return null;
        return .{ .product = self, .sat = sat, .from = from, .until = until, .tx = tx };
    }

    pub fn stateAt(self: *const Product, sat: types.SatId, t: GpsTime, tx: ?Transmitter) ?State {
        const sr = self.seriesOf(sat) orelse return null;
        const o = orbitAt(sr, self.interval_s, t) orelse return null;
        const c = clockAt(sr, t) orelse return null;
        var pos: coord.Ecef = .fromArray(o.pos);
        var vel: coord.Ecef = .fromArray(o.vel);
        if (tx) |transmitter| {
            const omega_e = gnss.constants.get(sat.system).omega_e;
            const off = phaseCentreOffset(pos, vel, omega_e, t, transmitter);
            const before = orbitAt(sr, self.interval_s, t.addSeconds(-pco_rate_half_s)) orelse return null;
            const after = orbitAt(sr, self.interval_s, t.addSeconds(pco_rate_half_s)) orelse return null;
            const off_a = phaseCentreOffset(.fromArray(before.pos), .fromArray(before.vel), omega_e, t.addSeconds(-pco_rate_half_s), transmitter);
            const off_b = phaseCentreOffset(.fromArray(after.pos), .fromArray(after.vel), omega_e, t.addSeconds(pco_rate_half_s), transmitter);
            pos = pos.add(off);
            vel = vel.add(off_b.sub(off_a));
        }
        return .{
            .pos = pos,
            .vel = vel,
            .clock_bias_s = c.bias_s,
            .clock_drift = c.drift,
            .rel_s = -2.0 * coord.Ecef.fromArray(o.pos).dot(.fromArray(o.vel)) / (constants.light_speed * constants.light_speed),
        };
    }

    pub fn trim(self: *Product, from: GpsTime, to: GpsTime) void {
        for (self.series) |*sr| {
            std.debug.assert(sr.base == 0);
            var position_first: usize = 0;
            while (position_first < sr.pos.len and sr.t0.addSeconds(@as(f64, @floatFromInt(position_first)) * self.interval_s).lessThan(from)) position_first += 1;
            var position_end: usize = sr.pos.len;
            while (position_end > position_first and to.lessThan(sr.t0.addSeconds(@as(f64, @floatFromInt(position_end - 1)) * self.interval_s))) position_end -= 1;
            sr.base = position_first;
            sr.pos = sr.pos[position_first..position_end];

            const clock_from = from.addSeconds(-max_clock_gap_s);
            const clock_to = to.addSeconds(max_clock_gap_s);
            var clock_first: usize = 0;
            while (clock_first < sr.clock.len and sr.clock[clock_first].t.lessThan(clock_from)) clock_first += 1;
            var clock_end: usize = sr.clock.len;
            while (clock_end > clock_first and clock_to.lessThan(sr.clock[clock_end - 1].t)) clock_end -= 1;
            sr.clock = sr.clock[clock_first..clock_end];
        }
    }
};

fn intervalInRange(s: f64) bool {
    return s >= min_interval_s and s <= max_interval_s;
}

fn epochInRange(t: GpsTime) bool {
    return t.ms >= 0 and t.ms < max_epoch_ms and t.sub_ms >= 0 and t.sub_ms < 1;
}

fn phaseCentreOffset(pos: coord.Ecef, vel: coord.Ecef, omega_e: f64, t: GpsTime, tx: Transmitter) coord.Ecef {
    return core.attitude.BodyAxes.of(tx.law, pos, vel, omega_e, core.sun.positionEcef(t)).toEcef(tx.body_m);
}

pub const Handle = struct {
    product: *const Product,
    sat: types.SatId,
    from: GpsTime,
    until: GpsTime,
    tx: ?Transmitter,

    pub fn state(self: Handle, t: GpsTime) State {
        std.debug.assert(!t.lessThan(self.from) and !self.until.lessThan(t));
        return self.product.stateAt(self.sat, t, self.tx) orelse unreachable;
    }
};

const Orbit = struct { pos: [3]f64, vel: [3]f64 };

fn windowStart(sr: *const Series, interval_s: f64, t: GpsTime) ?usize {
    if (sr.pos.len < window + 1) return null;
    const x = t.secondsSince(sr.t0) / interval_s - @as(f64, @floatFromInt(sr.base));
    const first = @floor(x) - (window / 2 - 1);
    if (!(first >= 0 and first <= @as(f64, @floatFromInt(sr.pos.len - (window + 1))))) return null;
    return @intFromFloat(first);
}

fn lagrange(sr: *const Series, interval_s: f64, first: usize, x: f64) ?Orbit {
    var y: [window][3]f64 = undefined;
    for (0..window) |j| y[j] = sr.pos[first + j] orelse return null;
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

fn orbitAt(sr: *const Series, interval_s: f64, t: GpsTime) ?Orbit {
    const first = windowStart(sr, interval_s, t) orelse return null;
    const x = t.secondsSince(sr.t0) / interval_s - @as(f64, @floatFromInt(sr.base));
    const a = lagrange(sr, interval_s, first, x) orelse return null;
    const b = lagrange(sr, interval_s, first + 1, x) orelse return null;
    const w = x - @floor(x);
    var out: Orbit = undefined;
    for (0..3) |c| {
        out.pos[c] = (1.0 - w) * a.pos[c] + w * b.pos[c];
        out.vel[c] = (1.0 - w) * a.vel[c] + w * b.vel[c] + (b.pos[c] - a.pos[c]) / interval_s;
    }
    return out;
}

const Clock = struct { bias_s: f64, drift: f64 };

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

fn bridged(span_s: f64) bool {
    return span_s > 0 and span_s <= max_clock_gap_s;
}

fn clockAt(sr: *const Series, t: GpsTime) ?Clock {
    const c = sr.clock;
    const i = clockPair(c, t) orelse return null;
    const a = c[i];
    const b = c[i + 1];
    const span = b.t.secondsSince(a.t);
    if (!bridged(span)) return null;
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
