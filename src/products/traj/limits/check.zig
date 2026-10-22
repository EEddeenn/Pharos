//! The limits held against the stored path: its knots and the quintic pieces between them, read as the path moves,
//! at its height. The 3D speed, acceleration and jerk by their exact extremes on each piece, from the Bernstein form
//! of their squares; the six quantities of the local frame sampled on each piece at a stated density and refined
//! where they bend, a piece read only where an exact bound on it lets the quantity matter; a piece shorter than
//! `segment_model.short_s` gives its speeds, accelerations and jerk at its knots, which hold the motion's velocities and
//! accelerations. The two knots of a step are each its own piece's: the jerk is a piece's own, and a velocity step is
//! no acceleration. Over EGM96 each point is read in the geoid's cell it lies in (`frame.Cells`).
const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const trajectory = @import("domain/trajectory/trajectory");
const model = @import("products/traj/input/model");
const frame = @import("products/traj/motion/geometry/frame");
const segment_model = @import("products/traj/construction/segments");
const construction = @import("products/traj/construction/build");
const geoid = @import("domain/earth/geoid/model");

const Scalar = @import("domain/trajectory/hermite").Scalar;

const Ecef = coordinates.Ecef;
const Knot = trajectory.Knot;

/// A stretch of time where a limit is broken, its ends included, and the segment it begins in.
pub const Stretch = struct {
    from: f64,
    to: f64,
    segment: usize,
};

/// Where a quantity passes its limit's bounds farthest, or comes nearest them: its value, signed, and when.
pub const Worst = struct { value: f64, time: f64, segment: usize };

pub const Check = struct {
    /// Null where the quantity has no value over the limit's segments: a direction of travel, at rest throughout.
    worst: ?Worst,
    broken: []const Stretch,

    pub fn holds(self: Check) bool {
        return self.broken.len == 0;
    }
};

/// A piece is read at this many parts, each halved at most `most_halvings` times while it bends.
const parts_per_piece = 16;
const most_halvings = 6;
/// The exact extremes, and the parts of a piece beyond a level, are found to this many halvings of it.
const finest_halvings = 40;
/// How finely the extremes and the stretches are found, in tolerances.
const resolution = 0.1;
/// Bounds of the motion's frame over a piece: the least radius its normal turns by, and of the geoid over EGM96 its
/// greatest slope and curvature (each far above the model's).
const least_radius_m: f64 = 6.3e6;
const geoid_slope: f64 = 1e-2;
const geoid_curvature_per_m: f64 = 1e-6;

/// What a limit allows of its quantity: how far a value is past its bounds, in its tolerance; above 1, broken.
const Allowed = struct {
    quantity: model.Quantity,
    bounds: model.Bounds,

    /// By the quantity's kind, of its bound or one unit, whichever is larger: what the stored quintics leave of the
    /// motion as stated, with ten times to spare.
    fn tolerance(self: Allowed, limit: f64) f64 {
        return switch (self.quantity.family()) {
            .speed => 1e-6 * @max(@abs(limit), 1),
            .acceleration => 1e-3 * @max(@abs(limit), 1),
            .jerk => 1e-2 * @max(@abs(limit), 1),
            .altitude => 1e-6,
        };
    }

    fn excess(self: Allowed, value: f64) f64 {
        var out = -std.math.inf(f64);
        if (self.bounds.max()) |max| out = @max(out, ((if (self.quantity.signed()) @abs(value) else value) - max) / self.tolerance(max));
        if (self.bounds.min()) |min| out = @max(out, (min - value) / self.tolerance(min));
        return out;
    }

    /// The excess an upper bound of the size and a lower bound of the value may reach.
    fn reach(self: Allowed, high: f64, low: f64) f64 {
        var out = -std.math.inf(f64);
        if (self.bounds.max()) |max| out = @max(out, (high - max) / self.tolerance(max));
        if (self.bounds.min()) |min| out = @max(out, (min - low) / self.tolerance(min));
        return out;
    }
};

/// A polynomial on [0, 1] in Bernstein form: the square of a quintic's derivative is of degree 8 at most, of a
/// position 10.
const Bernstein = struct {
    degree: usize,
    c: [11]f64,

    fn of(power: [11]f64, degree: usize) Bernstein {
        var out: Bernstein = .{ .degree = degree, .c = @splat(0) };
        for (0..degree + 1) |j| for (0..j + 1) |i| {
            out.c[j] += power[i] * binomial(j, i) / binomial(degree, i);
        };
        return out;
    }

    fn high(self: Bernstein) f64 {
        return std.mem.max(f64, self.c[0 .. self.degree + 1]);
    }

    fn low(self: Bernstein) f64 {
        return std.mem.min(f64, self.c[0 .. self.degree + 1]);
    }

    /// Its halves, by de Casteljau's steps at the middle.
    fn halves(self: Bernstein) [2]Bernstein {
        var work = self.c;
        var out: [2]Bernstein = .{ self, self };
        for (1..self.degree + 1) |level| {
            for (0..self.degree + 1 - level) |i| work[i] = (work[i] + work[i + 1]) / 2;
            out[0].c[level] = work[0];
            out[1].c[self.degree - level] = work[self.degree - level];
        }
        return out;
    }
};

/// A polynomial's greatest value on [0, 1], and where it has it.
const Peak = struct { value: f64, u: f64 };

/// A knot and the piece that follows it, with its quintics.
const Piece = struct {
    k0: Knot,
    k1: Knot,
    segment: usize,
    coefficients: [3]Scalar.Quintic,

    fn of(k0: Knot, k1: Knot, segment: usize) Piece {
        return .{ .k0 = k0, .k1 = k1, .segment = segment, .coefficients = trajectory.coefficients(k0, k1) };
    }

    fn duration(self: *const Piece) f64 {
        return self.k1.t - self.k0.t;
    }

    fn time(self: *const Piece, u: f64) f64 {
        return if (u == 1) self.k1.t else self.k0.t + self.duration() * u;
    }

    /// The state at u, the knots' own at its ends.
    fn state(self: *const Piece, u: f64) trajectory.State {
        var out: [4][3]f64 = undefined;
        for (self.coefficients, 0..) |c, axis| {
            const m = Scalar.motion(c, self.duration(), u);
            out[0][axis] = m.position;
            out[1][axis] = m.velocity;
            out[2][axis] = m.acceleration;
            out[3][axis] = m.jerk;
        }
        const jerk: Ecef = .fromArray(out[3]);
        if (u == 0) return .{ .pos = self.k0.pos, .vel = self.k0.vel, .acc = self.k0.acc, .jerk = jerk };
        if (u == 1) return .{ .pos = self.k1.pos, .vel = self.k1.vel, .acc = self.k1.acc, .jerk = jerk };
        return .{ .pos = .fromArray(out[0]), .vel = .fromArray(out[1]), .acc = .fromArray(out[2]), .jerk = jerk };
    }

    /// Over EGM96 each point in the geoid's cell `cells` gives it, or without them in the one it lies in.
    fn reading(self: *const Piece, u: f64, datum: model.Altitude, cells: ?*frame.Cells) frame.Reading {
        const s = self.state(u);
        return .of(s, datum, if (datum == .egm96) if (cells) |c| c.of(self.k0, self.k1, self.time(u), s.pos) else null else null);
    }

    /// The order-th derivative in time, axis by axis, in powers of u.
    fn derivative(self: *const Piece, order: usize) [3][6]f64 {
        var out: [3][6]f64 = @splat(@splat(0));
        const h = self.duration();
        for (self.coefficients, &out) |c, *d| {
            for (order..6) |i| {
                var factor: f64 = 1;
                for (0..order) |k| factor *= @floatFromInt(i - k);
                d[i - order] = c[i] * factor / std.math.pow(f64, h, @floatFromInt(order));
            }
        }
        return out;
    }
};

const Sample = struct { u: f64, excess: f64, value: ?f64 };

/// One limit's walk over its pieces.
const Walk = struct {
    allowed: Allowed,
    datum: model.Altitude,
    worst: ?struct { excess: f64, value: f64, time: f64, segment: usize } = null,
    broken: std.ArrayList(Stretch) = .empty,
    samples: std.ArrayList(Sample) = .empty,
    cells: frame.Cells = .{},

    fn consider(self: *Walk, piece: *const Piece, u: f64, value: f64) void {
        const e = self.allowed.excess(value);
        if (self.worst == null or e > self.worst.?.excess) self.worst = .{ .excess = e, .value = value, .time = piece.time(u), .segment = piece.segment };
    }

    fn worstExcess(self: *const Walk) f64 {
        return if (self.worst) |w| w.excess else -std.math.inf(f64);
    }

    /// The quantity at u of a piece, where it has a value.
    fn local(self: *Walk, piece: *const Piece, u: f64) ?f64 {
        const r = piece.reading(u, self.datum, &self.cells);
        return switch (self.allowed.quantity) {
            .horizontal_speed => r.horizontal_speed_mps,
            .lateral_acceleration => r.lateral_acceleration_mps2,
            .forward_acceleration => r.forward_acceleration_mps2,
            .climb_rate => r.climb_mps,
            .vertical_acceleration => r.vertical_acceleration_mps2,
            .altitude => r.altitude_m,
            .speed3d, .acceleration3d, .jerk3d => unreachable,
        };
    }

    fn sample(self: *Walk, piece: *const Piece, u: f64) Sample {
        const value = self.local(piece, u);
        return .{ .u = u, .excess = if (value) |v| self.allowed.excess(v) else -std.math.inf(f64), .value = value };
    }

    /// A piece's quantity of the local frame: its samples in order, each part halved while its points bend by more
    /// than the resolution where it could pass the bound or the worst; then its worst and its broken stretches.
    fn sampled(self: *Walk, arena: std.mem.Allocator, piece: *const Piece) std.mem.Allocator.Error!void {
        self.samples.clearRetainingCapacity();
        var a = self.sample(piece, 0);
        try self.samples.append(arena, a);
        for (1..parts_per_piece + 1) |k| {
            const b = self.sample(piece, @as(f64, @floatFromInt(k)) / parts_per_piece);
            const m = self.sample(piece, (a.u + b.u) / 2);
            try self.refine(arena, piece, a, m, b, 0);
            a = b;
        }
        for (self.samples.items) |s| if (s.value) |v| self.consider(piece, s.u, v);
        for (self.samples.items[0 .. self.samples.items.len - 1], self.samples.items[1..]) |s0, s1| {
            if (s0.excess <= 1 and s1.excess <= 1) continue;
            const from = if (s0.excess > 1) s0.u else self.crossing(piece, s0.u, s1.u);
            const to = if (s1.excess > 1) s1.u else self.crossing(piece, s1.u, s0.u);
            try add(arena, &self.broken, .{ .from = piece.time(from), .to = piece.time(to), .segment = piece.segment });
        }
    }

    fn refine(self: *Walk, arena: std.mem.Allocator, piece: *const Piece, a: Sample, m: Sample, b: Sample, depth: usize) std.mem.Allocator.Error!void {
        const q1 = self.sample(piece, (3 * a.u + b.u) / 4);
        const q3 = self.sample(piece, (a.u + 3 * b.u) / 4);
        const points = [_]Sample{ a, q1, m, q3, b };
        var top = -std.math.inf(f64);
        var bottom = std.math.inf(f64);
        for (points) |s| {
            top = @max(top, s.excess);
            bottom = @min(bottom, s.excess);
        }
        const bend = @max(bent(a, m, b), @max(bent(a, q1, m), bent(m, q3, b)));
        const matters = top + 4 * bend > self.worstExcess() + resolution or (top + 4 * bend > 1 and bottom - 4 * bend <= 1);
        if (depth < most_halvings and bend > resolution and matters) {
            try self.refine(arena, piece, a, q1, m, depth + 1);
            return self.refine(arena, piece, m, q3, b, depth + 1);
        }
        try self.samples.appendSlice(arena, &.{ q1, m, q3, b });
    }

    /// A piece shorter than `segment_model.short_s`: its quantity read at its two knots alone, its jerk the change of
    /// acceleration between them over its time.
    fn atKnots(self: *Walk, arena: std.mem.Allocator, piece: *const Piece) std.mem.Allocator.Error!void {
        var broken: [2]bool = undefined;
        for ([_]f64{ 0, 1 }, &broken) |u, *b| {
            const knot = if (u == 0) piece.k0 else piece.k1;
            const value: ?f64 = switch (self.allowed.quantity) {
                .speed3d => knot.vel.norm(),
                .acceleration3d => knot.acc.norm(),
                .jerk3d => piece.k1.acc.sub(piece.k0.acc).norm() / piece.duration(),
                else => self.local(piece, u),
            };
            if (value) |v| self.consider(piece, u, v);
            b.* = if (value) |v| self.allowed.excess(v) > 1 else false;
        }
        if (broken[0] and broken[1]) return add(arena, &self.broken, .{ .from = piece.k0.t, .to = piece.k1.t, .segment = piece.segment });
        for (broken, [_]f64{ piece.k0.t, piece.k1.t }) |b, t| if (b) try add(arena, &self.broken, .{ .from = t, .to = t, .segment = piece.segment });
    }

    /// Where the excess passes 1 between a part of a piece at or under it and one over it, to the rounding of u.
    fn crossing(self: *Walk, piece: *const Piece, inside: f64, outside: f64) f64 {
        var in = inside;
        var out = outside;
        while (true) {
            const mid = (in + out) / 2;
            if (mid == in or mid == out) return out;
            if (self.sample(piece, mid).excess > 1) out = mid else in = mid;
        }
    }

    /// A piece's 3D speed, acceleration or jerk: its exact extremes, and where the bounds are passed.
    fn exact(self: *Walk, arena: std.mem.Allocator, piece: *const Piece, norm: Bernstein) std.mem.Allocator.Error!void {
        if (self.allowed.bounds.max()) |max| {
            const top = greatest(norm);
            self.consider(piece, top.u, @sqrt(@max(0, top.value)));
            const over = max + self.allowed.tolerance(max);
            try self.beyond(arena, piece, norm, over * over, 0, 1, 0);
        }
        if (self.allowed.bounds.min()) |min| {
            const bottom = greatest(negated(norm));
            self.consider(piece, bottom.u, @sqrt(@max(0, -bottom.value)));
            const under = min - self.allowed.tolerance(min);
            if (under > 0) try self.beyond(arena, piece, negated(norm), -(under * under), 0, 1, 0);
        }
    }

    /// The parts of [low, high] where p passes a level, to `finest_halvings` halvings of the piece: a part that
    /// halving no longer tells is counted in whole.
    fn beyond(self: *Walk, arena: std.mem.Allocator, piece: *const Piece, p: Bernstein, level: f64, low: f64, high: f64, depth: usize) std.mem.Allocator.Error!void {
        if (p.high() <= level) return;
        if (p.low() > level or depth == finest_halvings) return add(arena, &self.broken, .{ .from = piece.time(low), .to = piece.time(high), .segment = piece.segment });
        const two = p.halves();
        const mid = (low + high) / 2;
        try self.beyond(arena, piece, two[0], level, low, mid, depth + 1);
        try self.beyond(arena, piece, two[1], level, mid, high, depth + 1);
    }
};

/// The true extremes of a stored path, read as the limits read it: its greatest 3D speed, acceleration and jerk, and
/// its least and greatest altitude above EGM96 (a PHT holds no reference of its own).
pub const Extremes = struct { speed_mps: f64, acceleration_mps2: f64, jerk_mps3: f64, min_altitude_m: f64, max_altitude_m: f64 };

pub fn checkPath(gpa: std.mem.Allocator, arena: std.mem.Allocator, path: *const construction.Path, limits: []const model.Limit, altitude: model.Altitude) std.mem.Allocator.Error![]const Check {
    if (limits.len == 0) return &.{};
    const knots = path.trajectory.knots;
    const segments = try gpa.alloc(usize, knots.len - 1);
    defer gpa.free(segments);
    for (segments, 0..) |*segment, k| segment.* = std.sort.partitionPoint(construction.SegmentInfo, path.segments, k, atOrBefore) - 1;
    const covered = try gpa.alloc(bool, path.segments.len);
    defer gpa.free(covered);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const out = try arena.alloc(Check, limits.len);
    for (limits, out) |limit, *check| {
        _ = scratch.reset(.retain_capacity);
        @memset(covered, limit.over == null);
        for (limit.over orelse &.{}) |segment| covered[segment] = true;
        var pieces: std.ArrayList(usize) = .empty;
        for (segments, 0..) |segment, k| if (knots[k + 1].t > knots[k].t and covered[segment]) try pieces.append(scratch.allocator(), k);
        check.* = try evaluate(arena, scratch.allocator(), knots, segments, pieces.items, .{ .quantity = limit.quantity, .bounds = limit.bounds }, altitude);
    }
    return out;
}

pub fn extremes(allocator: std.mem.Allocator, knots: []const Knot) std.mem.Allocator.Error!Extremes {
    const segments = try allocator.alloc(usize, knots.len - 1);
    defer allocator.free(segments);
    @memset(segments, 0);
    var pieces: std.ArrayList(usize) = .empty;
    defer pieces.deinit(allocator);
    for (0..knots.len - 1) |k| if (knots[k + 1].t > knots[k].t) try pieces.append(allocator, k);
    // A path of one instant has no piece: its extremes are its knots'.
    if (pieces.items.len == 0) {
        var instant: Extremes = .{ .speed_mps = 0, .acceleration_mps2 = 0, .jerk_mps3 = 0, .min_altitude_m = std.math.inf(f64), .max_altitude_m = -std.math.inf(f64) };
        for (knots) |k| {
            const altitude = geoid.altitude(coordinates.ecefToLla(k.pos));
            instant.speed_mps = @max(instant.speed_mps, k.vel.norm());
            instant.acceleration_mps2 = @max(instant.acceleration_mps2, k.acc.norm());
            instant.min_altitude_m = @min(instant.min_altitude_m, altitude);
            instant.max_altitude_m = @max(instant.max_altitude_m, altitude);
        }
        return instant;
    }
    var out: Extremes = undefined;
    // A limit of 0 reads its quantity's greatest value as its worst, and of a least altitude of 0, the least.
    const asked = [_]struct { quantity: model.Quantity, bounds: model.Bounds, into: *f64 }{
        .{ .quantity = .speed3d, .bounds = .{ .maximum = 0 }, .into = &out.speed_mps },
        .{ .quantity = .acceleration3d, .bounds = .{ .maximum = 0 }, .into = &out.acceleration_mps2 },
        .{ .quantity = .jerk3d, .bounds = .{ .maximum = 0 }, .into = &out.jerk_mps3 },
        .{ .quantity = .altitude, .bounds = .{ .minimum = 0 }, .into = &out.min_altitude_m },
        .{ .quantity = .altitude, .bounds = .{ .maximum = 0 }, .into = &out.max_altitude_m },
    };
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (asked) |a| {
        _ = scratch.reset(.retain_capacity);
        const c = try evaluate(scratch.allocator(), scratch.allocator(), knots, segments, pieces.items, .{ .quantity = a.quantity, .bounds = a.bounds }, .egm96);
        a.into.* = c.worst.?.value;
    }
    return out;
}

fn binomial(n: usize, k: usize) f64 {
    var out: f64 = 1;
    for (0..k) |i| out *= @as(f64, @floatFromInt(n - i)) / @as(f64, @floatFromInt(i + 1));
    return out;
}

/// The greatest value of a polynomial on [0, 1], to a billionth of it, and where; of -p, the least.
fn greatest(p: Bernstein) Peak {
    var best: Peak = if (p.c[0] >= p.c[p.degree]) .{ .value = p.c[0], .u = 0 } else .{ .value = p.c[p.degree], .u = 1 };
    const Part = struct { p: Bernstein, low: f64, high: f64 };
    var stack: [2 * (finest_halvings + 1)]Part = undefined;
    var count: usize = 1;
    stack[0] = .{ .p = p, .low = 0, .high = 1 };
    while (count > 0) {
        count -= 1;
        const part = stack[count];
        if (part.p.high() <= best.value + 1e-9 * @abs(best.value) or part.high - part.low < 1.0 / @as(f64, 1 << finest_halvings)) continue;
        const two = part.p.halves();
        const mid = (part.low + part.high) / 2;
        if (two[0].c[p.degree] > best.value) best = .{ .value = two[0].c[p.degree], .u = mid };
        stack[count] = .{ .p = two[1], .low = mid, .high = part.high };
        stack[count + 1] = .{ .p = two[0], .low = part.low, .high = mid };
        count += 2;
    }
    return best;
}

fn negated(p: Bernstein) Bernstein {
    var out = p;
    for (out.c[0 .. p.degree + 1]) |*c| c.* = -c.*;
    return out;
}

/// The square of a vector polynomial's norm (its axes of degree `degree` in u), in Bernstein form.
fn square(axes: []const [6]f64, degree: usize) Bernstein {
    var power: [11]f64 = @splat(0);
    for (axes) |a| for (0..degree + 1) |i| for (0..degree + 1) |j| {
        power[i + j] += a[i] * a[j];
    };
    return .of(power, 2 * degree);
}

/// A derivative's part along a unit vector, and the rest across it.
fn split(d: [3][6]f64, along: Ecef) struct { along: [1][6]f64, across: [3][6]f64 } {
    const n = along.toArray();
    var on: [6]f64 = @splat(0);
    for (0..6) |i| on[i] = d[0][i] * n[0] + d[1][i] * n[1] + d[2][i] * n[2];
    var across = d;
    for (&across, n) |*a, k| for (a, on) |*x, y| {
        x.* -= y * k;
    };
    return .{ .along = .{on}, .across = across };
}

/// How far a middle point lies off the line of its neighbours: nothing where a point has no value.
fn bent(a: Sample, m: Sample, b: Sample) f64 {
    if (a.value == null or m.value == null or b.value == null) return 0;
    return @abs(m.excess - (a.excess + b.excess) / 2);
}

/// Appends a stretch, joined to the last one where they meet.
fn add(arena: std.mem.Allocator, list: *std.ArrayList(Stretch), s: Stretch) std.mem.Allocator.Error!void {
    if (list.items.len > 0 and list.items[list.items.len - 1].to >= s.from and list.items[list.items.len - 1].from <= s.from) {
        const last = &list.items[list.items.len - 1];
        last.to = @max(last.to, s.to);
        return;
    }
    try list.append(arena, s);
}

/// An upper bound of the excess of a limit's quantity on a piece, exact: from the Bernstein bounds of the motion's
/// squares, and the turn of the local frame over the piece.
fn bound(piece: *const Piece, allowed: Allowed, datum: model.Altitude) f64 {
    const q = allowed.quantity;
    const v = piece.derivative(1);
    const a = piece.derivative(2);
    switch (q) {
        .speed3d => return reach(allowed, square(&v, 4)),
        .acceleration3d => return reach(allowed, square(&a, 3)),
        .jerk3d => return reach(allowed, square(&piece.derivative(3), 2)),
        else => {},
    }
    const speed = @sqrt(square(&v, 4).high());
    const acceleration = @sqrt(square(&a, 3).high());
    const middle = coordinates.ecefToLla(piece.state(0.5).pos);
    const up: Ecef = .{ .x = @cos(middle.lat_rad) * @cos(middle.lon_rad), .y = @cos(middle.lat_rad) * @sin(middle.lon_rad), .z = @sin(middle.lat_rad) };
    // The frame turns over the piece by at most its length from the middle over the least radius.
    const turn = speed * piece.duration() / 2 / least_radius_m;
    const egm96: f64 = if (datum == .egm96) 1 else 0;
    switch (q) {
        .horizontal_speed => {
            const across = square(&split(v, up).across, 4);
            return allowed.reach(@sqrt(across.high()) + 2 * speed * turn, @sqrt(@max(0, across.low())) - 2 * speed * turn);
        },
        .lateral_acceleration, .forward_acceleration => return allowed.reach(@sqrt(square(&split(a, up).across, 3).high()) + 2 * acceleration * turn, 0),
        .climb_rate => return allowed.reach(@sqrt(square(&split(v, up).along, 4).high()) + speed * (turn + egm96 * geoid_slope), 0),
        .vertical_acceleration => {
            const vertical = @sqrt(square(&split(a, up).along, 3).high()) + acceleration * (turn + egm96 * geoid_slope);
            return allowed.reach(vertical + speed * speed * (1 / least_radius_m + egm96 * geoid_curvature_per_m), 0);
        },
        .altitude => {
            const h0 = piece.reading(0, datum, null).altitude_m;
            const h1 = piece.reading(1, datum, null).altitude_m;
            const reach_m = speed * (1 + egm96 * geoid_slope) * piece.duration() / 2;
            return allowed.reach(@max(h0, h1) + reach_m, @min(h0, h1) - reach_m);
        },
        .speed3d, .acceleration3d, .jerk3d => unreachable,
    }
}

fn reach(allowed: Allowed, norm: Bernstein) f64 {
    return allowed.reach(@sqrt(norm.high()), @sqrt(@max(0, norm.low())));
}

fn atOrBefore(k: usize, segment: construction.SegmentInfo) bool {
    return segment.first_knot <= k;
}

/// A limit over its pieces (by their first knots), the pieces read in the order of their bounds, the highest
/// first, while a bound may pass the tolerance or top the worst.
fn evaluate(arena: std.mem.Allocator, scratch: std.mem.Allocator, knots: []const Knot, segments: []const usize, pieces: []const usize, allowed: Allowed, datum: model.Altitude) std.mem.Allocator.Error!Check {
    // Only the altitude and its rates are of the plan's reference.
    const q = allowed.quantity;
    const reference: model.Altitude = if (q == .altitude or q == .climb_rate or q == .vertical_acceleration) datum else .ellipsoid;
    const Bounded = struct { piece: usize, bound: f64 };
    const ordered = try scratch.alloc(Bounded, pieces.len);
    for (ordered, pieces) |*o, k| o.* = .{ .piece = k, .bound = bound(&Piece.of(knots[k], knots[k + 1], segments[k]), allowed, reference) };
    std.mem.sort(Bounded, ordered, {}, struct {
        fn higher(_: void, x: Bounded, y: Bounded) bool {
            return x.bound > y.bound or (x.bound == y.bound and x.piece < y.piece);
        }
    }.higher);
    var walk: Walk = .{ .allowed = allowed, .datum = reference };
    for (ordered) |o| {
        if (o.bound <= 1 and o.bound <= walk.worstExcess() + resolution) break;
        const piece: Piece = .of(knots[o.piece], knots[o.piece + 1], segments[o.piece]);
        if (piece.duration() < segment_model.short_s and q != .altitude) try walk.atKnots(scratch, &piece) else switch (q) {
            .speed3d => try walk.exact(scratch, &piece, square(&piece.derivative(1), 4)),
            .acceleration3d => try walk.exact(scratch, &piece, square(&piece.derivative(2), 3)),
            .jerk3d => try walk.exact(scratch, &piece, square(&piece.derivative(3), 2)),
            else => try walk.sampled(scratch, &piece),
        }
    }
    std.mem.sort(Stretch, walk.broken.items, {}, struct {
        fn earlier(_: void, x: Stretch, y: Stretch) bool {
            return x.from < y.from or (x.from == y.from and x.segment < y.segment);
        }
    }.earlier);
    var broken: std.ArrayList(Stretch) = .empty;
    for (walk.broken.items) |s| try add(arena, &broken, s);
    const worst: ?Worst = if (walk.worst) |w| .{ .value = w.value, .time = w.time, .segment = w.segment } else null;
    return .{ .worst = worst, .broken = broken.items };
}
