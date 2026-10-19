//! The one segment that is solved: the path of least jerk through places at stated times. Between two knots the
//! path is the quintic Hermite of their states (position, velocity, acceleration); the positions are held, and the
//! velocities and accelerations are what makes least
//!
//!     J = sum over the pieces k of  integral of |jerk|^2 dt  +  (tie / h_k^2) integral of |acceleration|^2 dt
//!
//! with h_k the piece's duration and tie = 1e-6: the jerk decides wherever it can, and the acceleration breaks its
//! ties (a piece from a free start to a free end has no jerk on any line through its places). A knot's velocity and
//! acceleration are held where the segment's ends state them. Each axis is one such problem of one matrix.
//!
//! The numerics: each piece takes its positions as their own difference (no position of the Earth's size enters);
//! each knot's unknowns are scaled by the shorter of its gaps (the velocity by it, the acceleration by its square);
//! the held values are eliminated; the band of half-width 3 is factored as L D L'. The solution is then checked:
//! its residual is taken in f128, of the exact piece integrals, and the correction it gives applied, until a
//! correction moves no piece of the path by more than `settled_m`, or by more than the rounding of the piece's own
//! velocities and accelerations. A plan whose solution does not settle within `most_corrections` is badly scaled
//! for f64 (gaps of very different lengths), and is refused with the pieces where it does not.
const std = @import("std");

const tie: f64 = 1e-6;
/// A correction that moves no piece by more than this, in metres, ends the check.
const settled_m: f64 = 1e-9;
/// Or that moves it by no more than this part of what its velocities and accelerations move it by: a few units
/// in the last place of a double, the rounding of the solution itself.
const rounding: f64 = 4 * std.math.floatEps(f64);
/// The corrections the check takes at most.
const most_corrections = 4;
/// The axes a through solves together: three of position, and the height.
pub const axes = 4;

pub const Error = error{OutOfMemory};

/// The jerk's and the acceleration's integrals over a piece of duration h, as quadratic forms in
/// (p0, v0 h, a0 h^2, p1, v1 h, a1 h^2), times h^5 and h^3: those of the quintic Hermite basis.
const jerk_gram = [6][6]f64{
    .{ 720, 360, 60, -720, 360, -60 },
    .{ 360, 192, 36, -360, 168, -24 },
    .{ 60, 36, 9, -60, 24, -3 },
    .{ -720, -360, -60, 720, -360, 60 },
    .{ 360, 168, 24, -360, 192, -36 },
    .{ -60, -24, -3, 60, -36, 9 },
};
const acceleration_gram = [6][6]comptime_float{
    .{ 120.0 / 7.0, 60.0 / 7.0, 3.0 / 7.0, -120.0 / 7.0, 60.0 / 7.0, -3.0 / 7.0 },
    .{ 60.0 / 7.0, 192.0 / 35.0, 11.0 / 35.0, -60.0 / 7.0, 108.0 / 35.0, -4.0 / 35.0 },
    .{ 3.0 / 7.0, 11.0 / 35.0, 3.0 / 35.0, -3.0 / 7.0, 4.0 / 35.0, 1.0 / 70.0 },
    .{ -120.0 / 7.0, -60.0 / 7.0, -3.0 / 7.0, 120.0 / 7.0, -60.0 / 7.0, 3.0 / 7.0 },
    .{ 60.0 / 7.0, 108.0 / 35.0, 4.0 / 35.0, -60.0 / 7.0, 192.0 / 35.0, -11.0 / 35.0 },
    .{ -3.0 / 7.0, -4.0 / 35.0, 1.0 / 70.0, 3.0 / 7.0, -11.0 / 35.0, 3.0 / 35.0 },
};

/// The piece's form, J_k = x' K x / h^5: the jerk's, with the tie's acceleration.
fn form(comptime T: type) [6][6]T {
    var k: [6][6]T = undefined;
    for (&k, jerk_gram, acceleration_gram) |*row, j, a| {
        for (row, j, a) |*entry, jv, av| entry.* = @as(T, jv) + @as(T, tie) * @as(T, av);
    }
    return k;
}
const form64 = form(f64);
const form128 = form(f128);

/// Where a piece's unknowns stand in its form: its first knot's velocity and acceleration, its last knot's.
const slots = [4]usize{ 1, 2, 4, 5 };

/// The largest the velocity's and the acceleration's basis functions reach over a piece: a change of a knot's
/// velocity by dv moves the piece by at most 16/81 h |dv|, of its acceleration by da at most 54/3125 h^2 |da|.
const velocity_reach = 16.0 / 81.0;
const acceleration_reach = 54.0 / 3125.0;

pub fn Knot(comptime count: usize) type {
    return struct { velocity: [count]f64, acceleration: [count]f64 };
}

pub fn Held(comptime count: usize) type {
    return struct {
        /// The velocity and the acceleration of the first knot, each axis; null where free.
        velocity: ?[count]f64,
        acceleration: ?[count]f64,
        /// The velocity and the acceleration of the last knot (at rest, nothing); null where free.
        end: ?Knot(count),
    };
}

pub fn Outcome(comptime count: usize) type {
    return union(enum) {
        solved: []const Knot(count),
        /// The pieces (each by the index of its first knot) that the check did not settle.
        unsettled: []const usize,
    };
}

/// `times` and `values` of the knots on `count` axes, the first the segment's start; `held` its ends. The knots'
/// velocities and accelerations, or the pieces where f64 cannot solve it.
pub fn solve(comptime count: usize, arena: std.mem.Allocator, times: []const f64, values: []const [count]f64, held: Held(count)) Error!Outcome(count) {
    const n = times.len;
    const size = 2 * n;
    const first: usize = if (held.acceleration != null) 2 else if (held.velocity != null) 1 else 0;
    const end: usize = if (held.end != null) size - 2 else size;
    const free = end - first;
    // Unknowns of all axes, in their physical units: u[axis][2k] the velocity of knot k, u[axis][2k + 1] its
    // acceleration.
    var u: [count][]f64 = undefined;
    for (&u, 0..) |*column, axis| {
        column.* = try arena.alloc(f64, size);
        @memset(column.*, 0);
        if (held.velocity) |v| column.*[0] = v[axis];
        if (held.acceleration) |a| column.*[1] = a[axis];
        if (held.end) |e| {
            column.*[size - 2] = e.velocity[axis];
            column.*[size - 1] = e.acceleration[axis];
        }
    }
    const scale = try arena.alloc(f64, size);
    for (0..n) |k| {
        const before = if (k > 0) times[k] - times[k - 1] else std.math.inf(f64);
        const after = if (k + 1 < n) times[k + 1] - times[k] else std.math.inf(f64);
        const s = @min(before, after);
        scale[2 * k] = s;
        scale[2 * k + 1] = s * s;
    }
    // The band of the free unknowns, scaled: band[f][d] the entry (f, f - d).
    const band = try arena.alloc([4]f64, free);
    @memset(band, @splat(0));
    for (0..n - 1) |k| {
        const h = times[k + 1] - times[k];
        for (slots, 0..) |pi, a| {
            const i = 2 * k + a;
            if (i < first or i >= end) continue;
            for (slots[0 .. a + 1], 0..) |pj, b| {
                const j = 2 * k + b;
                if (j < first) continue;
                band[i - first][i - j] += form64[pi][pj] * reach(h, pi, scale[i]) * reach(h, pj, scale[j]) / h5(h);
            }
        }
    }
    const pivots = try factor(arena, band);
    for (pivots) |p| if (!(p > 0)) return .{ .unsettled = try everyPiece(arena, n) };

    const step = try arena.alloc(f64, free);
    // Each piece's correction over what settles it, the most of its axes.
    const moved = try arena.alloc(f64, n - 1);
    for (0..most_corrections + 1) |correction| {
        @memset(moved, 0);
        for (u, 0..) |column, axis| {
            gradient(count, times, values, axis, column, first, end, step);
            for (step, first..) |*r, i| r.* = -r.* / scale[i];
            solveBand(band, pivots, step);
            for (step, first..) |dz, i| column[i] += dz / scale[i];
            // The first solve is the answer; the corrections after it are its check.
            if (correction == 0) continue;
            for (moved, 0..) |*m, k| {
                const h = times[k + 1] - times[k];
                var change: f64 = 0;
                var motion: f64 = 0;
                for (2 * k..2 * k + 4) |i| {
                    const metres = if (i % 2 == 0) velocity_reach * h else acceleration_reach * h * h;
                    motion += @abs(column[i]) * metres;
                    if (i >= first and i < end) change += @abs(step[i - first] / scale[i]) * metres;
                }
                const over = change / @max(settled_m, rounding * motion);
                if (!(over <= m.*)) m.* = over;
            }
        }
        if (correction == 0) continue;
        var settled = true;
        for (moved) |m| settled = settled and m <= 1;
        if (settled) break;
        if (correction == most_corrections) {
            var pieces: std.ArrayList(usize) = .empty;
            for (moved, 0..) |m, k| if (!(m <= 1)) try pieces.append(arena, k);
            return .{ .unsettled = pieces.items };
        }
    }
    const knots = try arena.alloc(Knot(count), n);
    for (knots, 0..) |*knot, k| {
        for (u, 0..) |column, axis| {
            knot.velocity[axis] = column[2 * k];
            knot.acceleration[axis] = column[2 * k + 1];
        }
    }
    return .{ .solved = knots };
}

fn everyPiece(arena: std.mem.Allocator, n: usize) Error![]const usize {
    const pieces = try arena.alloc(usize, n - 1);
    for (pieces, 0..) |*p, k| p.* = k;
    return pieces;
}

fn h5(h: f64) f64 {
    const h2 = h * h;
    return h2 * h2 * h;
}

/// The factor of an unknown in the piece's form: its own unit over the piece's (the velocity times h, the
/// acceleration times h^2), divided by the unknown's scale.
fn reach(h: f64, slot: usize, scale: f64) f64 {
    return if (slot == 1 or slot == 4) h / scale else h * h / scale;
}

/// L D L' of the band in place: the factors of L below the diagonal, D's pivots returned.
fn factor(arena: std.mem.Allocator, band: [][4]f64) Error![]f64 {
    const pivots = try arena.alloc(f64, band.len);
    for (band, 0..) |*row, f| {
        // First each entry times its pivot, from the farthest in; then the pivot, and the entries themselves.
        var d: usize = 3;
        while (d >= 1) : (d -= 1) {
            if (d > f) continue;
            const g = f - d;
            for (d + 1..4) |e| {
                if (e > f) continue;
                row[d] -= row[e] * band[g][e - d];
            }
        }
        var pivot = row[0];
        for (1..4) |e| {
            if (e > f) continue;
            const l = row[e] / pivots[f - e];
            pivot -= l * row[e];
            row[e] = l;
        }
        pivots[f] = pivot;
    }
    return pivots;
}

fn solveBand(band: []const [4]f64, pivots: []const f64, y: []f64) void {
    for (y, 0..) |*value, f| {
        for (1..4) |d| if (d <= f) {
            value.* -= band[f][d] * y[f - d];
        };
    }
    for (y, pivots) |*value, p| value.* /= p;
    var f = y.len;
    while (f > 0) {
        f -= 1;
        for (1..4) |d| if (f + d < y.len) {
            y[f] -= band[f + d][d] * y[f + d];
        };
    }
}

/// Half the derivative of J by each free unknown of one axis at `u`, of the exact integrals, taken in f128.
fn gradient(comptime count: usize, times: []const f64, values: []const [count]f64, axis: usize, u: []const f64, first: usize, end: usize, out: []f64) void {
    var carried: [2]f128 = .{ 0, 0 };
    for (0..times.len - 1) |k| {
        const h = @as(f128, times[k + 1]) - @as(f128, times[k]);
        const h2 = h * h;
        const h5_128 = h2 * h2 * h;
        // The piece's state in its own units, its first position the origin.
        const x = [6]f128{
            0,
            @as(f128, u[2 * k]) * h,
            @as(f128, u[2 * k + 1]) * h2,
            @as(f128, values[k + 1][axis]) - @as(f128, values[k][axis]),
            @as(f128, u[2 * k + 2]) * h,
            @as(f128, u[2 * k + 3]) * h2,
        };
        var rows: [4]f128 = undefined;
        for (&rows, slots) |*r, p| {
            var sum: f128 = 0;
            for (form128[p][1..], x[1..]) |entry, value| sum += entry * value;
            r.* = sum;
        }
        // The two unknowns of this piece's first knot complete with it; its last knot's go on to the next piece.
        const sums = [2]f128{ carried[0] + rows[0] * h / h5_128, carried[1] + rows[1] * h2 / h5_128 };
        carried = .{ rows[2] * h / h5_128, rows[3] * h2 / h5_128 };
        for (sums, 2 * k..) |value, i| {
            if (i >= first and i < end) out[i - first] = @floatCast(value);
        }
    }
    for (carried, 2 * (times.len - 1)..) |value, i| {
        if (i >= first and i < end) out[i - first] = @floatCast(value);
    }
}
