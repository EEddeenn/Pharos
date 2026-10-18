//! The plan built forward, segment after segment from the start, each from the state the one before leaves, and
//! sampled into the knots of a PHT.
//!
//! A stay is a knot at rest at its end. A through is solved (`through.zig`) on four axes: the ECEF path P of least
//! jerk gives the horizontal track, and the height h* of least jerk through the places' heights (ellipsoidal) is its
//! fourth axis, held where P is held, at P's own rate of height. The path is the track at that height,
//! Q = P + (h* - h_P) up, with h_P and up the height and the normal of P: it passes every place, and where the
//! segment begins it has the state the segment before left. Q is not a quintic, so each piece between two places is
//! cut into as many equal pieces as make the quintic Hermite of their knots lie within `tolerance_m` of Q, measured
//! at a quarter, a half and three quarters of each, and, where Q stays in the receiver's domain, as many as the
//! domain's bound between knots needs: a knot at every place, and no more knots than a PHT holds.
const std = @import("std");
const shared = @import("shared");
const Ecef = shared.core.coord.Ecef;
const trajectory = shared.trajectory;
const Knot = trajectory.Knot;
const Scalar = trajectory.hermite.Scalar;
const model = @import("plan.zig").model;
const frame = @import("frame.zig");
const through = @import("through.zig");

/// How near the stored path stays to the built one, in metres.
const tolerance_m: f64 = 1e-6;
pub const max_knots = trajectory.pht.max_knots;

pub const Error = error{OutOfMemory};

pub const Built = struct {
    knots: []const Knot,
    /// Each segment's first knot: the one the segment before ends at.
    first_knots: []const usize,
};

pub const Refusal = union(enum) {
    /// A through whose solve did not settle in these pieces (each by its first knot, the segment's start 0).
    unsettled: struct { segment: usize, pieces: []const usize },
    /// The segment with which the path needs more knots than a PHT holds.
    knots: usize,
    /// A piece of a through whose motion cannot be stored: its quintics' rates would not be finite (a piece too short
    /// for them, or a path through the geocentre, where no normal lifts it).
    unstorable: struct { segment: usize, piece: usize },
};

pub const Outcome = union(enum) { built: Built, refused: Refusal };

const zero: Ecef = .{ .x = 0, .y = 0, .z = 0 };

/// The state a segment begins in, at a place: its velocity and acceleration null where the start leaves them free.
const State = struct { time: f64, place: *const model.Place, vel: ?Ecef, acc: ?Ecef };

/// `arena` holds the knots; `scratch` the solves and a refusal's pieces.
pub fn build(arena: std.mem.Allocator, scratch: std.mem.Allocator, plan: *const model.Plan) Error!Outcome {
    // Every through solved and cut first: the knots are counted before they are taken.
    const solved = try scratch.alloc(?Solved, plan.segments.len);
    const start = &plan.places[plan.start_place];
    var state: State = switch (plan.start) {
        .rest => .{ .time = 0, .place = start, .vel = zero, .acc = zero },
        .free => .{ .time = 0, .place = start, .vel = null, .acc = null },
        .moving => |v| .{ .time = 0, .place = start, .vel = v, .acc = null },
    };
    var count: usize = 1;
    for (plan.segments, solved, 0..) |segment, *out, i| {
        out.* = null;
        switch (segment.motion) {
            .stay => {
                count += 1;
                if (count > max_knots) return .{ .refused = .{ .knots = i } };
                state = .{ .time = segment.end, .place = state.place, .vel = zero, .acc = zero };
            },
            .through => |t| {
                const s = switch (try solveThrough(scratch, plan, state, t.visits, t.end == .rest)) {
                    .solved => |s| s,
                    .unsettled => |pieces| return .{ .refused = .{ .unsettled = .{ .segment = i, .pieces = pieces } } },
                };
                for (s.cuts, 0..) |*cuts, k| {
                    cuts.* = switch (s.cut(k, max_knots - count)) {
                        .cuts => |n| n,
                        .knots => return .{ .refused = .{ .knots = i } },
                        .unstorable => return .{ .refused = .{ .unstorable = .{ .segment = i, .piece = k } } },
                    };
                    count += cuts.*;
                }
                out.* = s;
                const last = s.knot(s.times.len - 1);
                state = .{ .time = last.t, .place = &plan.places[t.visits[t.visits.len - 1].place], .vel = last.vel, .acc = last.acc };
            },
        }
    }
    const knots = try arena.alloc(Knot, count);
    const first_knots = try arena.alloc(usize, plan.segments.len);
    knots[0] = .{ .t = 0, .pos = start.ecef, .vel = zero, .acc = zero };
    var written: usize = 1;
    for (plan.segments, solved, first_knots) |segment, s, *first| {
        first.* = written - 1;
        if (s) |*t| {
            knots[written - 1] = t.knot(0);
            for (t.cuts, 0..) |cuts, k| {
                for (1..cuts + 1) |c| {
                    knots[written] = t.point(k, c, cuts);
                    written += 1;
                }
            }
        } else {
            knots[written] = .{ .t = segment.end, .pos = knots[written - 1].pos, .vel = zero, .acc = zero };
            written += 1;
        }
    }
    return .{ .built = .{ .knots = knots, .first_knots = first_knots } };
}

/// A solved through: its knots' times, positions and heights, and the solve's velocities and accelerations.
const Solved = struct {
    times: []const f64,
    values: []const [through.axes]f64,
    states: []const through.Knot,
    /// The state it begins in.
    before: State,
    rest: bool,
    /// Into how many pieces each piece between two places is cut.
    cuts: []usize,

    /// The knot at place k, the segment's start 0: at the place's position exactly, in the state held there where
    /// one is, or the path's.
    fn knot(self: *const Solved, k: usize) Knot {
        const t = self.times[k];
        const pos = Ecef.fromArray(self.values[k][0..3].*);
        if (self.rest and k == self.times.len - 1) return .{ .t = t, .pos = pos, .vel = zero, .acc = zero };
        var p: [through.axes]frame.Jet = undefined;
        for (&p, self.values[k], self.states[k].velocity, self.states[k].acceleration) |*axis, value, first, second| {
            axis.* = .{ .value = value, .first = first, .second = second };
        }
        const q = lifted(p);
        if (k == 0) return .{ .t = t, .pos = pos, .vel = self.before.vel orelse q.vel, .acc = self.before.acc orelse q.acc };
        return .{ .t = t, .pos = pos, .vel = q.vel, .acc = q.acc };
    }

    /// The knot at the end of cut c of piece k cut `cuts` times.
    fn point(self: *const Solved, k: usize, c: usize, cuts: usize) Knot {
        if (c == 0) return self.knot(k);
        if (c == cuts) return self.knot(k + 1);
        const u = @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(cuts));
        const q = self.at(k, u);
        return .{ .t = self.times[k] + (self.times[k + 1] - self.times[k]) * u, .pos = q.pos, .vel = q.vel, .acc = q.acc };
    }

    /// Q at the fraction u of piece k.
    fn at(self: *const Solved, k: usize, u: f64) trajectory.State {
        const h = self.times[k + 1] - self.times[k];
        var p: [through.axes]frame.Jet = undefined;
        for (&p, 0..) |*axis, a| {
            const coefficients = Scalar.quintic(self.values[k][a], self.states[k].velocity[a], self.states[k].acceleration[a], self.values[k + 1][a], self.states[k + 1].velocity[a], self.states[k + 1].acceleration[a], h);
            const m = Scalar.motion(coefficients, h, u);
            axis.* = .{ .value = m.position, .first = m.velocity, .second = m.acceleration };
        }
        return lifted(p);
    }

    const Cut = union(enum) { cuts: usize, knots, unstorable };

    /// The fewest equal cuts of piece k, found by doubling, whose knots' quintics lie within the tolerance of Q and,
    /// as far as finer cuts bring it nearer, within the bound of the receiver's domain between knots; `knots` where
    /// more than `most` would be needed.
    fn cut(self: *const Solved, k: usize, most: usize) Cut {
        var cuts: usize = 1;
        // The time the bound does not hold, at the two doublings before.
        var unbounded: [2]f64 = @splat(std.math.inf(f64));
        while (cuts <= most) : (cuts *= 2) {
            switch (self.within(k, cuts)) {
                .unstorable => return .unstorable,
                .finer => {},
                // The bound tightens as knots come nearer, unless it is the rounding of pieces too short; two
                // doublings that do not shorten the time it fails show that, and the domain check then refuses.
                .unbounded => |seconds| {
                    if (seconds == 0 or !(seconds < unbounded[0])) return .{ .cuts = cuts };
                    unbounded = .{ unbounded[1], seconds };
                },
            }
        }
        return .knots;
    }

    /// Whether the cuts hold the path (the time of the cut pieces the domain's bound does not hold, 0 where all are
    /// held or the path leaves the domain), or finer ones are needed, or no knots can: a quintic whose rates are
    /// not finite.
    fn within(self: *const Solved, k: usize, cuts: usize) union(enum) { unbounded: f64, finer, unstorable } {
        const span = self.times[k + 1] - self.times[k];
        var a = self.point(k, 0, cuts);
        var unbounded: f64 = 0;
        var leaves = !inside(a.pos, a.vel, a.acc);
        for (1..cuts + 1) |c| {
            const b = self.point(k, c, cuts);
            for ([_]f64{ 0.25, 0.5, 0.75 }) |f| {
                const t = a.t + (b.t - a.t) * f;
                const stored = trajectory.between(a, b, t);
                for ([_]Ecef{ stored.pos, stored.vel, stored.acc, stored.jerk }) |v| {
                    if (!(std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z))) return .unstorable;
                }
                const built = self.at(k, (t - self.times[k]) / span);
                if (!(stored.pos.sub(built.pos).norm() <= tolerance_m)) return .finer;
                leaves = leaves or !inside(built.pos, built.vel, built.acc);
            }
            leaves = leaves or !inside(b.pos, b.vel, b.acc);
            trajectory.checkKnot(&.{ a, b }, 1) catch |e| if (e == error.PathOutOfRange) {
                unbounded += b.t - a.t;
            };
            a = b;
        }
        return .{ .unbounded = if (leaves) 0 else unbounded };
    }
};

/// Whether a state lies in the receiver's domain.
fn inside(pos: Ecef, vel: Ecef, acc: Ecef) bool {
    return trajectory.positionInRange(pos) and vel.norm() <= trajectory.max_speed_mps and acc.norm() <= trajectory.max_acceleration_mps2;
}

/// The path at the track's state and the height's: P lifted along its normal to the height h*.
fn lifted(p: [through.axes]frame.Jet) trajectory.State {
    const position: frame.Vector = p[0..3].*;
    const local: frame.Frame = .at(position);
    const lift = p[3].sub(local.height);
    var q: frame.Vector = undefined;
    for (&q, position, local.up) |*out, axis, normal| out.* = axis.add(lift.mul(normal));
    return .{
        .pos = .{ .x = q[0].value, .y = q[1].value, .z = q[2].value },
        .vel = .{ .x = q[0].first, .y = q[1].first, .z = q[2].first },
        .acc = .{ .x = q[0].second, .y = q[1].second, .z = q[2].second },
        .jerk = zero,
    };
}

fn solveThrough(scratch: std.mem.Allocator, plan: *const model.Plan, before: State, visits: []const model.Visit, rest: bool) Error!union(enum) { solved: Solved, unsettled: []const usize } {
    const n = visits.len + 1;
    const times = try scratch.alloc(f64, n);
    const values = try scratch.alloc([through.axes]f64, n);
    times[0] = before.time;
    values[0] = valuesAt(before.place);
    for (visits, times[1..], values[1..]) |visit, *t, *v| {
        t.* = visit.time;
        v.* = valuesAt(&plan.places[visit.place]);
    }
    // The height held at P's own rates where the state before is held.
    const local: frame.Frame = .at(frame.positionJet(before.place.ecef, before.vel orelse zero, before.acc orelse zero));
    const held: through.Held = .{
        .velocity = if (before.vel) |v| .{ v.x, v.y, v.z, local.height.first } else null,
        .acceleration = if (before.acc) |a| .{ a.x, a.y, a.z, local.height.second } else null,
        .rest = rest,
    };
    return switch (try through.solve(scratch, times, values, held)) {
        .solved => |states| .{ .solved = .{ .times = times, .values = values, .states = states, .before = before, .rest = rest, .cuts = try scratch.alloc(usize, n - 1) } },
        .unsettled => |pieces| .{ .unsettled = pieces },
    };
}

/// A place's three ECEF coordinates and its height as the plan gives it: the through's axes.
fn valuesAt(place: *const model.Place) [through.axes]f64 {
    return .{ place.ecef.x, place.ecef.y, place.ecef.z, place.height };
}
