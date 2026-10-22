//! Cut the built motion into stored quintic pieces.
//!
//! Each segment is cut into stretches at its joints: a through at its places; a run where its guide's pieces meet,
//! at its guide's places, and over EGM96 where its track crosses a line of the geoid's grid. Where the motion steps
//! at a joint, two knots share its time: a step of acceleration (a corner's tangent point, a join of two
//! curvatures), or of velocity too (the geoid's slope, a Bezier's joint, a corner too gentle to round). Each stretch
//! is cut by halving, in the order of time, every piece whose knots' quintic Hermite lies farther than `tolerance_m`
//! from the built motion, measured at a quarter, a half and three quarters of it, the receiver's domain tested first:
//! where the built motion leaves it, nothing more is halved and the path kept as cut, out of the domain from that
//! time; where it stays in, every piece too whose knots' bound of the domain fails, while halving shortens the time it
//! fails. Count knots against the construction budget before they are taken.
const std = @import("std");
const diagnostics = @import("base/diagnostics");
const trajectory = @import("domain/trajectory/trajectory");
const motion = @import("products/traj/motion/profile");
const segments = @import("products/traj/construction/segments");

const Ecef = @import("domain/earth/coordinates").Ecef;
const max_knots = segments.max_knots;

const Diagnostics = diagnostics.Diagnostics;
const Knot = trajectory.Knot;

/// How near the stored path stays to the built one, in metres.
const tolerance_m: f64 = 1e-6;

pub const Error = diagnostics.InputError;

pub const RunPiece = struct {
    first: Knot,
    last: Knot,
    side: motion.Side,
};

pub const SampledSpan = struct { piece: RunPiece, cuts: []const f64 };
pub const SampledRun = struct { motion: motion.Run, spans: []const SampledSpan };
pub const SampledThrough = struct { solved: segments.Solved, cuts: []const []const f64 };

pub const Sampler = struct {
    scratch: std.mem.Allocator,
    diags: *Diagnostics,
    count: usize = 1,
    outside: *?segments.Outside,

    pub fn take(self: *Sampler, i: usize, more: usize) Error!void {
        self.count += more;
        if (self.count > max_knots) return segments.fail(self.diags, try segments.path(self.diags, i, ""), "the path needs more than {d} knots", .{max_knots});
    }
};

/// What a stretch is cut from: a piece of a through, or a stretch of a run.
pub const Source = union(enum) {
    through: struct { solved: *const segments.Solved, piece: usize },
    run: struct { motion: *const motion.Run, piece: *const RunPiece },

    /// The knot at the fraction u of it, its own knots at its ends.
    pub fn point(self: Source, u: f64) Knot {
        switch (self) {
            .through => |th| {
                if (u == 0) return th.solved.knot(th.piece);
                if (u == 1) return th.solved.knot(th.piece + 1);
                const q = th.solved.at(th.piece, u);
                const t0 = th.solved.times[th.piece];
                return .{ .t = t0 + (th.solved.times[th.piece + 1] - t0) * u, .pos = q.pos, .vel = q.vel, .acc = q.acc };
            },
            .run => |r| {
                if (u == 0) return r.piece.first;
                if (u == 1) return r.piece.last;
                return r.motion.knot(r.piece.first.t + (r.piece.last.t - r.piece.first.t) * u, r.piece.side);
            },
        }
    }

    fn built(self: Source, t: f64) motion.Sample {
        return switch (self) {
            .through => |th| th.solved.at(th.piece, (t - th.solved.times[th.piece]) / (th.solved.times[th.piece + 1] - th.solved.times[th.piece])),
            .run => |r| r.motion.state(t, r.piece.side),
        };
    }
};

const Within = union(enum) {
    holds,
    finer,
    /// The domain's bound between its knots fails.
    unbounded,
    /// A quintic whose rates are not finite.
    unstorable,
    leaves: Leaving,
};

/// Where the built motion is first found out of the receiver's domain, and the bound it breaks there.
const Leaving = struct { time: f64, reason: trajectory.DomainError };

/// Complete each sampled piece without mutating the prepared geometry.
pub fn sampleRun(sampler: *Sampler, i: usize, ready: *const segments.ReadyRun, before: ?Knot) Error!SampledRun {
    const prepared = &ready.prepared;
    const spans = try sampler.scratch.alloc(SampledSpan, prepared.spans.len);
    var last = before;
    for (prepared.spans, spans, 0..) |span, *out, k| {
        const own = prepared.motion.knot(span.from_s, span.side);
        const first = if (last) |previous| switch (span.joint) {
            .smooth => previous,
            .acceleration => Knot{ .t = previous.t, .pos = previous.pos, .vel = previous.vel, .acc = own.acc },
            .velocity => Knot{ .t = previous.t, .pos = previous.pos, .vel = own.vel, .acc = own.acc },
        } else own;
        const piece: RunPiece = .{
            .first = first,
            .last = if (k + 1 == prepared.spans.len) segments.knotOf(ready.end) else prepared.motion.knot(span.to_s, span.side),
            .side = span.side,
        };
        if (last != null and !std.meta.eql(piece.first, last.?)) try sampler.take(i, 1);
        const cuts = try cut(sampler, i, .{ .run = .{ .motion = &prepared.motion, .piece = &piece } });
        try sampler.take(i, cuts.len);
        out.* = .{ .piece = piece, .cuts = cuts };
        last = piece.last;
    }
    return .{ .motion = prepared.motion, .spans = spans };
}

/// A stretch cut by halving, level by level, the pieces that need it: each piece whose knots' quintic misses the
/// tolerance of the built motion; once none does, each piece whose knots' bound of the receiver's domain fails, as
/// far as halving brings it nearer. Where the built motion leaves the domain, the pieces it has then, the build
/// marked out of the domain. Where its pieces end, as fractions of it.
pub fn cut(b: *Sampler, i: usize, source: Source) Error![]const f64 {
    const Read = enum { holds, finer, unbounded };
    const Piece = struct { to: f64, read: ?Read = null };
    var pieces: std.ArrayList(Piece) = .empty;
    try pieces.append(b.scratch, .{ .to = 1 });
    var next: std.ArrayList(Piece) = .empty;
    const first = source.point(0);
    var left = false;
    if (trajectory.outside(first.pos, first.vel, first.acc)) |reason| {
        segments.Outside.mark(b.outside, i, first.t, reason);
        left = true;
    }
    // The share of the stretch the bound does not hold, at the two levels before.
    var unbounded: [2]f64 = @splat(std.math.inf(f64));
    while (true) {
        // The pieces not yet read, in the order of time, the first time the motion leaves the domain found first.
        var from: f64 = 0;
        var finer = false;
        var failing: f64 = 0;
        for (pieces.items) |*p| {
            if (p.read == null) p.read = switch (within(source, source.point(from), source.point(p.to), left)) {
                .unstorable => return switch (source) {
                    .through => |t| segments.fail(b.diags, try b.diags.arena.print("segments[{d}].through.places[{d}]", .{ i, t.piece }), "the path to this place cannot be stored: its velocity, acceleration or jerk is not finite", .{}),
                    .run => segments.fail(b.diags, try segments.path(b.diags, i, ""), "the path of this segment cannot be stored: its velocity, acceleration or jerk is not finite", .{}),
                },
                .leaves => |at| blk: {
                    segments.Outside.mark(b.outside, i, at.time, at.reason);
                    left = true;
                    break :blk .holds;
                },
                .holds => .holds,
                .finer => .finer,
                .unbounded => .unbounded,
            };
            if (p.read == .finer) finer = true;
            if (p.read == .unbounded) failing += p.to - from;
            from = p.to;
        }
        if (left) break;
        // The bound tightens as knots come nearer, unless it is the rounding of pieces too short; two levels that do
        // not shorten the share it fails show that, and the domain check then refuses.
        if (!finer) {
            if (failing == 0) break;
            if (!(failing < unbounded[0])) {
                for (pieces.items) |piece| if (piece.read == .unbounded) {
                    segments.Outside.mark(b.outside, i, source.point(piece.to).t, error.PathOutOfRange);
                    break;
                };
                break;
            }
            unbounded = .{ unbounded[1], failing };
        }
        const halved: Read = if (finer) .finer else .unbounded;
        next.clearRetainingCapacity();
        from = 0;
        for (pieces.items) |p| {
            if (p.read == halved) try next.appendSlice(b.scratch, &.{ .{ .to = (from + p.to) / 2 }, .{ .to = p.to } }) else try next.append(b.scratch, p);
            from = p.to;
        }
        if (b.count + next.items.len > max_knots) return segments.fail(b.diags, try segments.path(b.diags, i, ""), "the path needs more than {d} knots", .{max_knots});
        std.mem.swap(std.ArrayList(Piece), &pieces, &next);
    }
    const ends = try b.scratch.alloc(f64, pieces.items.len);
    for (ends, pieces.items) |*end, p| end.* = p.to;
    return ends;
}

/// What a piece between knots a and z holds of the motion: whether its quintic can be stored at all, before all
/// else; then, unless the motion has left the domain before it, the domain at the points it reads between its knots
/// and at z (a was read before), the first time it is left; then the tolerance, and the domain's bound between its
/// knots.
fn within(source: Source, a: Knot, z: Knot, left: bool) Within {
    const fractions = [_]f64{ 0.25, 0.5, 0.75 };
    var stored: [fractions.len]trajectory.State = undefined;
    for (&stored, fractions) |*q, f| {
        q.* = trajectory.between(a, z, a.t + (z.t - a.t) * f);
        for ([_]Ecef{ q.pos, q.vel, q.acc, q.jerk }) |v| if (!std.math.isFinite(v.norm())) return .unstorable;
    }
    if (left) return .holds;
    var in = a.t;
    var finer = false;
    for (stored, fractions) |q, f| {
        const t = a.t + (z.t - a.t) * f;
        const s = source.built(t);
        if (trajectory.outside(s.pos, s.vel, s.acc)) |reason| return .{ .leaves = leaving(source, in, t, reason) };
        in = t;
        if (!(q.pos.sub(s.pos).norm() <= tolerance_m)) finer = true;
    }
    if (trajectory.outside(z.pos, z.vel, z.acc)) |reason| return .{ .leaves = leaving(source, in, z.t, reason) };
    if (finer) return .finer;
    if (!trajectory.pathInRange(a, z)) return .unbounded;
    return .holds;
}

/// Where the built motion leaves the domain between a time it is in it and a later one it is not: by halving, the
/// first time found out of it, and the bound it breaks there.
fn leaving(source: Source, in: f64, out: f64, reason: trajectory.DomainError) Leaving {
    var low = in;
    var high = out;
    var why = reason;
    while (true) {
        const mid = (low + high) / 2;
        if (mid <= low or mid >= high) return .{ .time = high, .reason = why };
        const s = source.built(mid);
        if (trajectory.outside(s.pos, s.vel, s.acc)) |broken| {
            high = mid;
            why = broken;
        } else low = mid;
    }
}
