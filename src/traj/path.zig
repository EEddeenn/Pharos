//! The plan built forward, segment after segment from the start, each from the state the one before leaves, and
//! sampled into the knots of a PHT.
//!
//! A stay is a knot at rest at its end. A through is solved (`through.zig`) on four axes: the ECEF path P of least
//! jerk gives the horizontal track, and the height h* of least jerk through the places' heights (ellipsoidal) is its
//! fourth axis, held where P is held, at P's own rate of height. The path is the track at that height,
//! Q = P + (h* - h_P) up, with h_P and up the height and the normal of P: it passes every place, and where the
//! segment begins it has the state the segment before left; before a straight, a turn or an along it ends in that
//! segment's first state. Those three are runs (`motion.zig`): a ground track run by the speed's step at a height.
//!
//! Each segment is cut into stretches at its joints: a through at its places; a run where its guide's pieces meet,
//! at its guide's places, and over EGM96 where its track crosses a line of the geoid's grid. Where the motion steps
//! at a joint, two knots share its time: a step of acceleration (a corner's tangent point, a join of two
//! curvatures), or of velocity too (the geoid's slope, a Bezier's joint, a corner too gentle to round). Each stretch
//! is cut by halving, in the order of time, every piece whose knots' quintic Hermite lies farther than `tolerance_m`
//! from the built motion, measured at a quarter, a half and three quarters of it, the receiver's domain tested first:
//! where the built motion leaves it, nothing more is halved and the path kept as cut, out of the domain from that
//! time; where it stays in, every piece too whose knots' bound of the domain fails, while halving shortens the time it
//! fails. No more knots than a PHT holds, counted before they are taken.
const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const Ecef = core.coord.Ecef;
const Diagnostics = core.diagnostics.Diagnostics;
const Number = shared.json.node.Number;
const Range = shared.json.table.Range;
const trajectory = shared.trajectory;
const Knot = trajectory.Knot;
const Scalar = trajectory.hermite.Scalar;
const model = @import("plan.zig").model;
const frame = @import("frame.zig");
const through = @import("through.zig");
const track = @import("track.zig");
const guide = @import("guide.zig");
const motion = @import("motion.zig");

/// How near the stored path stays to the built one, in metres.
const tolerance_m: f64 = 1e-6;
/// A piece of the stored path shorter than this carries its knots' rounding as motion: it is read at its knots
/// alone, and no gentle corner's arc is built as one.
pub const short_s: f64 = 1e-2;
pub const max_knots = trajectory.pht.max_knots;
/// Within this angle of the point opposite where a straight begins (the flattening's share of a half turn), the
/// geodesics from it part: several reach a place there.
const parting_deg = 180 * (1 - core.constants.wgs_axis_b / core.constants.wgs_axis_a);

pub const Error = core.diagnostics.InputError;

pub const Built = struct {
    knots: []const Knot,
    /// Each segment's first knot: the one the segment before ends at.
    first_knots: []const usize,
    /// When each segment ends.
    ends: []const f64,
    /// Each segment's length over the ground, and the speed over the ground it ends at: in the plan's terms.
    lengths: []const f64,
    end_speeds: []const f64,
    /// Where the built motion is first found outside the receiver's domain.
    outside: ?Outside,
};

pub const Outside = struct { segment: usize, time: f64, reason: trajectory.Error };

const zero: Ecef = .{ .x = 0, .y = 0, .z = 0 };

/// The state a segment begins in.
const State = struct {
    time: f64,
    /// The knot's position, velocity and acceleration; the velocity and acceleration null where the start, or a
    /// through before a run, leaves them to the segment.
    pos: Ecef,
    vel: ?Ecef,
    acc: ?Ecef,
    /// The height above the ellipsoid: as the plan gives it where the state is at a place.
    height: f64,
    place: ?usize,
    /// The foot on the ellipsoid, and over the ground the direction of travel (none at rest) and the speed (none
    /// where free).
    foot: Ecef,
    tangent: ?Ecef,
    speed: ?f64,
    /// The altitude in the plan's reference and its first and second rates, exactly as the segment before left
    /// them; null where they are read off the state.
    vertical: ?[3]f64,
    /// The guide an along left, and the ground length on it where it did.
    on: ?struct { guide: usize, length: f64 } = null,
};

/// How a stretch begins: where the motion goes on, where its acceleration may step, or its velocity too.
const Joint = enum { smooth, acceleration, velocity };

const Stretch = struct {
    t0: f64,
    t1: f64,
    joint: Joint,
    side: motion.Side,
    /// The knots it begins and ends at, as written.
    a: Knot = undefined,
    b: Knot = undefined,
    /// Where its pieces end, as fractions of it: the last at 1.
    cuts: []const f64 = &.{},
};

const Prepared = struct {
    run: motion.Run,
    stretches: []Stretch,
    /// Where it ends exactly: at a place.
    snap: ?Ecef,
    /// Whether it ends at rest, as the plan states.
    rest: bool,
};

/// A run made ready, and the state it leaves.
const Ready = struct { prepared: Prepared, end: State };

const Segment = union(enum) {
    /// The knot at its end.
    stay: Knot,
    through: Solved,
    run: Prepared,
};

const Builder = struct {
    plan: *const model.Plan,
    scratch: std.mem.Allocator,
    diags: *Diagnostics,
    shapes: []?guide.Shape,
    count: usize = 1,
    outside: ?Outside = null,

    fn fail(self: *Builder, where: []const u8, comptime fmt: []const u8, args: anytype) Error {
        try self.diags.err(.invalid_segment, where, fmt, args);
        return error.InvalidInput;
    }

    fn path(self: *Builder, i: usize, key: []const u8) Error![]const u8 {
        return if (key.len == 0) self.diags.arena.print("segments[{d}]", .{i}) else self.diags.arena.print("segments[{d}].{s}", .{ i, key });
    }

    fn take(self: *Builder, i: usize, more: usize) Error!void {
        self.count += more;
        if (self.count > max_knots) return self.fail(try self.path(i, ""), "the path needs more knots than the {d} a PHT holds", .{max_knots});
    }

    /// A time that must come after the segment's start: where a time before follows from a speed, the plan's text
    /// cannot tell it.
    fn after(self: *Builder, i: usize, key: []const u8, time: f64, begin: f64) Error!void {
        // The time it begins at follows from a length and a speed: written as a number, not as a bound of the text.
        const range: Range = .{ .min = begin, .open_min = true };
        if (!range.holds(time)) return self.fail(try self.path(i, key), "must be above {f}, got {f}", .{ Number{ .value = begin, .apart = time }, Number{ .value = time, .outside = range } });
    }

    /// A segment's end within the longest a trajectory lasts.
    fn endsInTime(self: *Builder, i: usize, end: f64) Error!void {
        if (end > trajectory.max_duration_s) return self.fail(try self.path(i, ""), "ends {f} s from the start, and a trajectory lasts at most {d} s", .{ Number{ .value = end, .outside = .{ .max = trajectory.max_duration_s } }, trajectory.max_duration_s });
    }

    fn spanEnd(self: *Builder, i: usize, span: model.Span, begin: f64) Error!f64 {
        const end = switch (span) {
            .duration => |length| begin + length,
            .until => |t| t,
        };
        switch (span) {
            .duration => if (!(end > begin)) return self.fail(try self.path(i, "for"), "must end the {s} after it begins at {f} s, got an end at {f} s", .{ model.Kind.words.get(self.plan.segments[i].motion), Number{ .value = begin }, Number{ .value = end } }),
            .until => |t| try self.after(i, "time", t, begin),
        }
        try self.endsInTime(i, end);
        return end;
    }

    fn mark(self: *Builder, i: usize, time: f64, reason: trajectory.Error) void {
        if (self.outside == null or time < self.outside.?.time) self.outside = .{ .segment = i, .time = time, .reason = reason };
    }

    fn shape(self: *Builder, index: usize) Error!*const guide.Shape {
        if (self.shapes[index] == null) {
            const g = self.plan.guides[index];
            switch (try guide.build(self.scratch, self.plan.places, g)) {
                .shape => |s| self.shapes[index] = s,
                .fault => |fault| {
                    const kind = @tagName(g.shape);
                    switch (fault) {
                        .together => |p| return self.fail(try self.diags.arena.print("guides[{d}].{s}.places[{d}]", .{ index, kind, p }), "is at the point of the place before it", .{}),
                        .corner => |c| return self.fail(try self.diags.arena.print("guides[{d}].{s}.places[{d}]", .{ index, kind, c.place }), "the corner here needs {f} m of each leg to be rounded by the radius, and the leg to places[{d}] is {f} m", .{ Number{ .value = c.takes }, c.other, Number{ .value = c.leg } }),
                        .unsettled => |p| return self.fail(try self.diags.arena.print("guides[{d}].{s}.places[{d}]", .{ index, kind, p }), "the path from here passes too near the geocentre for its ground track to be found", .{}),
                    }
                },
            }
        }
        return &self.shapes[index].?;
    }
};

/// `arena` holds the knots; `scratch` the solves, the tracks and the guides. A fault that only the numbers show is
/// reported to `diags`.
pub fn build(arena: std.mem.Allocator, scratch: std.mem.Allocator, plan: *const model.Plan, diags: *Diagnostics) Error!Built {
    var b: Builder = .{ .plan = plan, .scratch = scratch, .diags = diags, .shapes = try scratch.alloc(?guide.Shape, plan.guides.len) };
    @memset(b.shapes, null);
    const segments = try scratch.alloc(Segment, plan.segments.len);
    const ends = try arena.alloc(f64, plan.segments.len);
    const lengths = try arena.alloc(f64, plan.segments.len);
    const end_speeds = try arena.alloc(f64, plan.segments.len);
    var state = startState(plan);
    // The knot written last, the one the next segment begins at: none until a segment says it.
    var last: ?Knot = if (state.vel != null and state.acc != null) knotOf(state) else null;
    var first = last;
    var i: usize = 0;
    while (i < plan.segments.len) : (i += 1) {
        const segment = plan.segments[i];
        switch (segment.motion) {
            .stay => {
                const end = try b.spanEnd(i, segment.span.?, state.time);
                try b.take(i, 1);
                const knot = atRest(end, state.pos);
                segments[i] = .{ .stay = knot };
                last = knot;
                state.time = end;
                if (state.vertical) |v| state.vertical = .{ v[0], 0, 0 };
            },
            .through => |t| {
                try b.after(i, "through.places[0].time", t.visits[0].time, state.time);
                const end = t.visits[t.visits.len - 1];
                try b.endsInTime(i, end.time);
                // Before a run the through ends in the run's first state: the run is made ready first, from the
                // through's last place.
                var next: ?Ready = null;
                if (t.end == .free and i + 1 < plan.segments.len and isRun(plan.segments[i + 1])) {
                    next = try prepare(&b, i + 1, placeState(plan, end.time, end.place));
                }
                const held: ?Knot = if (next) |*n| n.prepared.run.knot(n.prepared.run.start, n.prepared.stretches[0].side) else null;
                segments[i] = .{ .through = try solveThrough(&b, i, state, t.visits, t.end == .rest, held) };
                const s = &segments[i].through;
                if (first == null) first = s.knot(0);
                for (s.cuts, 0..) |*cuts, k| {
                    cuts.* = try cut(&b, i, .{ .through = .{ .solved = s, .piece = k } });
                    try b.take(i, cuts.len);
                }
                last = s.knot(s.times.len - 1);
                ends[i] = end.time;
                const place = &plan.places[end.place];
                state = .{
                    .time = end.time,
                    .pos = place.ecef,
                    .vel = last.?.vel,
                    .acc = last.?.acc,
                    .height = place.height,
                    .place = end.place,
                    .foot = footOf(place.ecef),
                    .tangent = null,
                    .speed = if (t.end == .rest) 0 else null,
                    .vertical = if (t.end == .rest) .{ place.altitude, 0, 0 } else null,
                };
                const n = next orelse continue;
                i += 1;
                segments[i] = .{ .run = n.prepared };
                last = try cutRun(&b, i, &segments[i].run, last);
                state = n.end;
            },
            .straight, .turn, .along => {
                const ready = try prepare(&b, i, state);
                segments[i] = .{ .run = ready.prepared };
                const p = &segments[i].run;
                last = try cutRun(&b, i, p, last);
                if (first == null) first = p.stretches[0].a;
                state = ready.end;
            },
        }
        ends[i] = state.time;
    }
    for (segments, lengths, end_speeds) |*segment, *length, *speed| switch (segment.*) {
        .stay => {
            length.* = 0;
            speed.* = 0;
        },
        .through => |*t| {
            length.* = groundLength(t);
            const end = t.knot(t.times.len - 1);
            speed.* = guide.footSpeed(end.pos, end.vel);
        },
        .run => |*p| {
            length.* = p.run.timing.length();
            speed.* = p.run.timing.v1;
        },
    };
    // The knots, now that they are counted.
    const knots = try arena.alloc(Knot, b.count);
    const first_knots = try arena.alloc(usize, plan.segments.len);
    knots[0] = first.?;
    var written: usize = 1;
    for (segments, first_knots) |*segment, *first_knot| {
        first_knot.* = written - 1;
        switch (segment.*) {
            .stay => |knot| {
                knots[written] = knot;
                written += 1;
            },
            .through => |*t| for (t.cuts, 0..) |cuts, piece| {
                const source: Source = .{ .through = .{ .solved = t, .piece = piece } };
                for (cuts) |u| {
                    knots[written] = source.point(u);
                    written += 1;
                }
            },
            .run => |*p| for (p.stretches) |*s| {
                if (!std.meta.eql(s.a, knots[written - 1])) {
                    knots[written] = s.a;
                    written += 1;
                }
                const source: Source = .{ .run = .{ .run = &p.run, .stretch = s } };
                for (s.cuts) |u| {
                    knots[written] = source.point(u);
                    written += 1;
                }
            },
        }
    }
    std.debug.assert(written == knots.len);
    return .{ .knots = knots, .first_knots = first_knots, .ends = ends, .lengths = lengths, .end_speeds = end_speeds, .outside = b.outside };
}

/// A through's length over the ground: its foot's speed over each piece between its places, as a guide's lengths are
/// found, each piece on its own to `length_settled` of its length in at most `length_parts` parts.
fn groundLength(s: *const Solved) f64 {
    var sum: f64 = 0;
    for (0..s.times.len - 1) |k| sum += guide.settledLength(ThroughPiece{ .solved = s, .piece = k }, length_settled, length_parts);
    return sum;
}

/// A through's length is told, not built on: each piece to a billionth of its length, in a bounded number of parts.
const length_settled = 1e-9;
const length_parts = 16;

/// A piece of a through by the fraction of it: its point, and its rate by that fraction.
const ThroughPiece = struct {
    solved: *const Solved,
    piece: usize,

    pub fn at(self: ThroughPiece, u: f64) [2]Ecef {
        const q = self.solved.at(self.piece, u);
        return .{ q.pos, q.vel.scale(self.solved.times[self.piece + 1] - self.solved.times[self.piece]) };
    }
};

fn isRun(segment: model.Segment) bool {
    return switch (segment.motion) {
        .straight, .turn, .along => true,
        .stay, .through => false,
    };
}

fn atRest(t: f64, pos: Ecef) Knot {
    return .{ .t = t, .pos = pos, .vel = zero, .acc = zero };
}

fn knotOf(state: State) Knot {
    return .{ .t = state.time, .pos = state.pos, .vel = state.vel.?, .acc = state.acc.? };
}

/// The foot on the ellipsoid of a position.
fn footOf(pos: Ecef) Ecef {
    const local: frame.Frame = .at(frame.positionJet(pos, zero, zero));
    return .{
        .x = pos.x - local.height.value * local.up[0].value,
        .y = pos.y - local.height.value * local.up[1].value,
        .z = pos.z - local.height.value * local.up[2].value,
    };
}

fn heightOf(pos: Ecef) f64 {
    return frame.Frame.at(frame.positionJet(pos, zero, zero)).height.value;
}

fn placeState(plan: *const model.Plan, time: f64, index: usize) State {
    const place = &plan.places[index];
    return .{ .time = time, .pos = place.ecef, .vel = null, .acc = null, .height = place.height, .place = index, .foot = footOf(place.ecef), .tangent = null, .speed = null, .vertical = null };
}

fn startState(plan: *const model.Plan) State {
    var state = placeState(plan, 0, plan.start_place);
    if (plan.start.course) |course| state.tangent = track.heading(state.foot, course);
    const speed = plan.start.speed orelse return state;
    state.speed = speed;
    state.vertical = .{ plan.places[plan.start_place].altitude, 0, 0 };
    if (speed == 0) {
        state.vel = zero;
        state.acc = zero;
    } else if (state.tangent) |tangent| {
        // Over the ground at the speed, at the place's height; its acceleration the first segment's. Without a
        // course, the first segment gives the direction, and so the velocity.
        state.vel = lifted(state.foot, tangent, speed, state.height);
    }
    return state;
}

/// The velocity of a point at a height above the ellipsoid that moves over it at a speed along a tangent.
fn lifted(foot: Ecef, tangent: Ecef, speed: f64, height: f64) Ecef {
    const m = track.metric;
    const scaled: Ecef = .{ .x = foot.x * m[0], .y = foot.y * m[1], .z = foot.z * m[2] };
    const n = track.normal(foot);
    const turned: Ecef = .{ .x = tangent.x * m[0], .y = tangent.y * m[1], .z = tangent.z * m[2] };
    return tangent.add(turned.sub(n.scale(n.dot(turned))).scale(height / scaled.norm())).scale(speed);
}

/// The altitude in the plan's reference with its rates: as the segment before left it, or read off the state; at
/// a place the place's own.
fn verticalOf(plan: *const model.Plan, state: State) [3]f64 {
    if (state.vertical) |v| return v;
    const local: frame.Frame = .at(frame.positionJet(state.pos, state.vel orelse zero, state.acc orelse zero));
    const h = switch (plan.altitude) {
        .ellipsoid => local.height,
        .egm96 => local.height.sub(core.geoid.Evaluator(frame.Jet, frame.Jet.Arithmetic).height(local.up)),
    };
    return .{ if (state.place) |p| plan.places[p].altitude else h.value, h.first, h.second };
}

/// The speeds and the duration of a run: where the shape fixes the length, a speed (the time follows) or a span (the
/// end speed follows), and neither keeps the speed; where it does not, a span with a speed or without. A free start
/// runs at the one speed that fits. A turn by rate or lateral keeps its speed.
fn timingOf(b: *Builder, i: usize, v0_given: ?f64, length: ?f64, span: ?f64, keeps: bool) Error!motion.Timing {
    const segment = b.plan.segments[i];
    if (keeps) {
        const v = v0_given orelse segment.speed.?;
        return .{ .v0 = v, .v1 = v, .duration = if (length) |l| l / v else span.? };
    }
    const l = length orelse {
        const v0 = v0_given orelse segment.speed.?;
        return .{ .v0 = v0, .v1 = segment.speed orelse v0, .duration = span.? };
    };
    if (segment.speed) |v1| {
        const v0 = v0_given orelse v1;
        return .{ .v0 = v0, .v1 = v1, .duration = 2 * l / (v0 + v1) };
    }
    const t = span orelse return .{ .v0 = v0_given.?, .v1 = v0_given.?, .duration = l / v0_given.? };
    const v0 = v0_given orelse l / t;
    const v1 = 2 * l / t - v0;
    if (v1 < 0) {
        const until = segment.span.? == .until;
        const begin = if (until) segment.span.?.until - t else 0;
        return b.fail(try b.path(i, if (until) "time" else "for"), "must be at most {f}, got {f}: over its {f} m from {f} m/s, any longer would end it below a speed of 0", .{ Number{ .value = begin + 2 * l / v0 }, Number{ .value = begin + t }, Number{ .value = l }, Number{ .value = v0 } });
    }
    return .{ .v0 = v0, .v1 = v1, .duration = t };
}

fn runTrack(b: *Builder, i: usize, from: track.Node, curvature: f64, length: f64) Error!track.Track {
    if (!(track.steps(curvature, length) <= max_knots)) return b.fail(try b.path(i, ""), "the path needs more knots than the {d} a PHT holds", .{max_knots});
    return track.run(b.scratch, from, curvature, length);
}

/// A run made ready: its ground track and timing, its height, its stretches, where it ends.
fn prepare(b: *Builder, i: usize, before: State) Error!Ready {
    const plan = b.plan;
    const segment = plan.segments[i];
    const scratch = b.scratch;
    const span: ?f64 = if (segment.span) |s| try b.spanEnd(i, s, before.time) - before.time else null;
    var foot = before.foot;
    var tangent = before.tangent;
    var ground: ?track.Track = null;
    // A track whose length follows from the timing: run once the timing's times are checked.
    var unrun: ?struct { from: track.Node, curvature: f64 } = null;
    var part: ?struct { shape: *const guide.Shape, from: f64, to: f64, joint: Joint, goes_on: bool } = null;
    var end_place: ?usize = null;
    var timing: motion.Timing = undefined;
    switch (segment.motion) {
        .straight => |s| {
            if (s.course) |course| tangent = track.heading(foot, course);
            var length = s.distance;
            if (s.to) |to| {
                const target = footOf(plan.places[to].ecef);
                if (std.meta.eql(target, foot)) return b.fail(try b.path(i, "straight.to"), "is where the straight begins, or right above or below it", .{});
                if (-track.normal(target).dot(track.normal(foot)) > @cos(core.constants.deg2rad(parting_deg))) return b.fail(try b.path(i, "straight.to"), "lies within {f} degrees of the point opposite where the straight begins, where several geodesics reach a place", .{Number{ .value = parting_deg }});
                const geodesic = (try track.toward(scratch, foot, target)) orelse return b.fail(try b.path(i, "straight.to"), "no geodesic to this place could be found: it lies too nearly opposite where the straight begins", .{});
                ground = geodesic;
                tangent = geodesic.nodes[0].tangent;
                length = geodesic.length;
                end_place = to;
            }
            timing = try timingOf(b, i, before.speed, length, span, false);
            if (ground == null) unrun = .{ .from = .{ .point = foot, .tangent = tangent.? }, .curvature = 0 };
        },
        .turn => |t| {
            const keeps = t.bend != .radius;
            const v = before.speed orelse segment.speed;
            const curvature = switch (t.bend) {
                .radius => |r| 1 / r,
                .rate => |rate| rate / v.?,
                .lateral => |lateral| lateral / (v.? * v.?),
            };
            const from: track.Node = .{ .point = foot, .tangent = tangent.? };
            var length: ?f64 = null;
            switch (t.end) {
                .open => {},
                // By an angle: the angle it turns through, its length the angle over the curvature.
                .by => |angle| length = angle / curvature,
                .onto => |onto| {
                    // Onto a course: reached after its course turns by more than nothing and at most a whole turn.
                    const right = @mod(onto - track.azimuth(from), core.constants.two_pi);
                    const angle = if (curvature > 0) (if (right == 0) core.constants.two_pi else right) else right - core.constants.two_pi;
                    ground = (try track.turning(scratch, from, curvature, angle, max_knots)) orelse return b.fail(try b.path(i, "turn.onto"), "the turn's course does not reach it within the knots a PHT holds", .{});
                    length = ground.?.length;
                },
            }
            timing = try timingOf(b, i, before.speed, length, span, keeps);
            if (ground == null) unrun = .{ .from = from, .curvature = curvature };
        },
        .along => |a| {
            const shape = try b.shape(a.guide);
            const g = plan.guides[a.guide];
            const continues = if (before.on) |on| on.guide == a.guide else false;
            const from = if (continues) before.on.?.length else shape.places[a.from];
            const to = shape.places[a.to];
            // Where an along goes on along its guide through a corner's arc, the motion goes on; at a Bezier's
            // joint, or a corner whose arc has no length, the velocity may turn; where it begins otherwise, its
            // acceleration may step.
            part = .{
                .shape = shape,
                .from = from,
                .to = to,
                .joint = if (!continues) .acceleration else if (shape.pieces[shape.piece(from)] == .arc) .smooth else .velocity,
                .goes_on = i + 1 < plan.segments.len and switch (plan.segments[i + 1].motion) {
                    .along => |next| next.guide == a.guide,
                    else => false,
                },
            };
            const p = shape.ground(shape.piece(from), from, .{ false, false });
            if (!continues) foot = p.point;
            tangent = p.tangent;
            if (g.shape == .bezier or a.to == g.places.len - 1) end_place = g.places[a.to];
            timing = try timingOf(b, i, before.speed, to - from, span, false);
        },
        .stay, .through => unreachable,
    }
    const end_time = before.time + timing.duration;
    if (!(end_time > before.time)) return b.fail(try b.path(i, ""), "must end after it begins at {f} s, and its length at its speeds takes no time", .{Number{ .value = before.time }});
    try b.endsInTime(i, end_time);
    if (unrun) |u| ground = try runTrack(b, i, u.from, u.curvature, timing.length());
    var run: motion.Run = .{
        .start = before.time,
        .timing = timing,
        .ground = if (ground) |g| .{ .track = g } else .{ .guide = .{ .shape = part.?.shape, .from = part.?.from } },
        .height = undefined,
    };
    var stretches: std.ArrayList(Stretch) = .empty;
    if (part) |p| {
        run.height = .{ .places = try profile(b, i, before, p.shape, p.from, p.to, timing.v0) };
        try alongStretches(scratch, &stretches, &run, p.shape, p.from, p.to, p.joint, p.goes_on);
        // A polyline's velocity steps only at a corner whose arc takes no time or is gentle: the motion turns there
        // at once, and is held against the receiver's domain by the acceleration its arc takes at the speed there.
        switch (plan.guides[segment.motion.along.guide].shape) {
            .polyline => |radius| for (stretches.items) |s| if (s.joint == .velocity) {
                const v = timing.at(s.t0 - before.time).first;
                if (!(v * v / radius <= trajectory.max_acceleration_mps2)) b.mark(i, s.t0, error.AccelerationOutOfRange);
            },
            .bezier => {},
        }
    } else {
        const v = verticalOf(plan, before);
        // A run after a free start or a through takes its own climb from its start.
        const from: [3]f64 = if (before.speed == null) .{ v[0], segment.climb orelse 0, 0 } else v;
        const rest = if (segment.speed) |s| s == 0 else false;
        const c1 = segment.climb orelse if (segment.altitude != null or rest) 0 else from[1];
        const h1 = segment.altitude orelse if (end_place) |e| plan.places[e].altitude else from[0] + timing.duration * (from[1] + c1) / 2;
        run.height = .{ .own = .{ .from = from, .to = .{ h1, c1 }, .duration = timing.duration } };
        const lines: []const f64 = if (plan.altitude == .egm96) try motion.crossings(scratch, &run.ground.track) else &.{};
        var t0 = before.time;
        for (0..lines.len + 1) |k| {
            const t1 = if (k < lines.len) before.time + timing.time(lines[k]) else end_time;
            if (!(t1 > t0)) continue;
            // A segment's acceleration may step where it begins; the geoid's grid lines step the velocity.
            try stretches.append(scratch, .{ .t0 = t0, .t1 = t1, .joint = if (stretches.items.len == 0) .acceleration else .velocity, .side = .{} });
            t0 = t1;
        }
        if (plan.altitude == .egm96) for (stretches.items) |*s| {
            const n = track.normal(run.foot((s.t0 + s.t1) / 2, .{}).point.point);
            const cell = try scratch.create(core.geoid.Cell);
            cell.* = .at(std.math.atan2(n.z, @sqrt(n.x * n.x + n.y * n.y)), std.math.atan2(n.y, n.x));
            s.side.cell = cell;
        };
    }
    const rest = if (segment.speed) |s| s == 0 else false;
    const last = stretches.items[stretches.items.len - 1];
    const end = run.knot(end_time, last.side);
    const end_foot = run.foot(end_time, last.side).point;
    const snap: ?Ecef = if (end_place) |e| plan.places[e].ecef else null;
    const at_foot = if (end_place) |e| footOf(plan.places[e].ecef) else end_foot.point;
    const height = switch (segment.motion) {
        .along => |a| plan.places[plan.guides[a.guide].places[a.to]].height,
        else => if (end_place) |e| plan.places[e].height else heightOf(end.pos),
    };
    return .{
        .prepared = .{ .run = run, .stretches = stretches.items, .snap = snap, .rest = rest },
        .end = .{
            .time = end_time,
            .pos = snap orelse end.pos,
            .vel = if (rest) zero else end.vel,
            .acc = if (rest) zero else end.acc,
            .height = height,
            .place = end_place,
            .foot = at_foot,
            .tangent = if (timing.v1 == 0) null else if (end_place != null) track.along(at_foot, end_foot.tangent) else end_foot.tangent,
            .speed = timing.v1,
            .vertical = switch (run.height) {
                .own => |v| .{ v.to[0], v.to[1], 0 },
                .places => null,
            },
            .on = if (part) |p| .{ .guide = segment.motion.along.guide, .length = p.to } else null,
        },
    };
}

/// An along's heights: of least jerk by ground length through its guide's places that it passes, from the height
/// it begins at, held there where it begins moving to the climb and its rate it begins with.
fn profile(b: *Builder, i: usize, before: State, shape: *const guide.Shape, from: f64, to: f64, v0: f64) Error!motion.Profile {
    const plan = b.plan;
    const a = plan.segments[i].motion.along;
    const g = plan.guides[a.guide];
    var lengths: std.ArrayList(f64) = .empty;
    var heights: std.ArrayList([1]f64) = .empty;
    try lengths.append(b.scratch, 0);
    try heights.append(b.scratch, .{before.height});
    for (a.from + 1..a.to + 1) |k| {
        if (g.shape == .bezier and k % 3 != 0) continue;
        const s = shape.places[k] - from;
        if (!(s > lengths.items[lengths.items.len - 1])) continue;
        try lengths.append(b.scratch, s);
        try heights.append(b.scratch, .{plan.places[g.places[k]].height});
    }
    std.debug.assert(lengths.items[lengths.items.len - 1] == to - from);
    // Held at the climb and its rate it begins with, where it begins moving: by length, the climb over the speed
    // and the rate over its square (the speed's step begins with no acceleration). A moving start is level, its
    // rate of climb free.
    var held: through.Held(1) = .{ .velocity = null, .acceleration = null, .end = null };
    if (before.speed != null and v0 > 0) {
        const local: frame.Frame = .at(frame.positionJet(before.pos, before.vel orelse zero, before.acc orelse zero));
        held.velocity = .{if (before.vel != null) local.height.first / v0 else 0};
        if (before.acc != null) held.acceleration = .{local.height.second / (v0 * v0)};
    }
    return switch (try through.solve(1, b.scratch, lengths.items, heights.items, held)) {
        .solved => |knots| blk: {
            const flat = try b.scratch.alloc(f64, heights.items.len);
            for (flat, heights.items) |*h, value| h.* = value[0];
            break :blk .{ .lengths = lengths.items, .heights = flat, .knots = knots };
        },
        .unsettled => b.fail(try b.path(i, "along"), "the heights along this part of the guide cannot be solved in double precision: the gaps between its places differ too much", .{}),
    };
}

/// A corner whose arc would change the velocity by less than this, and last less than `short_s`, steps the velocity
/// at its place instead: such an arc is a piece too short for a PHT's knots.
const gentle_mps: f64 = 1e-4;

/// An along's stretches: cut where its guide's pieces meet (a Bezier's joint may step the velocity, a polyline's
/// tangent point the acceleration) and at its heights' places, the first meeting the motion before by `first`;
/// `goes_on` where the next segment goes on along the guide. A part that takes no time (an arc too small for the
/// time's precision) is the step in velocity it makes; so is a gentle corner, its legs run on to its place, where the
/// velocity steps.
fn alongStretches(scratch: std.mem.Allocator, out: *std.ArrayList(Stretch), run: *const motion.Run, shape: *const guide.Shape, from: f64, to: f64, first: Joint, goes_on: bool) Error!void {
    const heights = run.height.places.lengths;
    // Of the pieces it runs on, from the first, whether each is a gentle corner's arc between two legs: one it runs
    // whole by its ends' velocities and its time; one at whose place it goes on from the along before, or on to the
    // along after, at the speed there, which both share.
    const base = shape.piece(from);
    const gentle = try scratch.alloc(bool, shape.piece(to) + 1 - base);
    for (gentle, base..) |*g, j| {
        g.* = false;
        if (shape.pieces[j] != .arc or j == 0 or j + 1 == shape.pieces.len or shape.pieces[j - 1] != .line or shape.pieces[j + 1] != .line) continue;
        const ends = shape.starts[j..][0..2].*;
        const place = ends[0] + shape.middles[j];
        // A half-arc under half an ulp of its place is no arc.
        if (!(place > ends[0] and place < ends[1])) continue;
        var speeds: [2]f64 = undefined;
        var duration: f64 = undefined;
        if (ends[0] > from and ends[1] < to) {
            const times = [2]f64{ run.timing.time(ends[0] - from), run.timing.time(ends[1] - from) };
            for (&speeds, times) |*v, t| v.* = run.timing.at(t).first;
            duration = times[1] - times[0];
        } else if ((place == from and first == .smooth) or (place == to and goes_on)) {
            speeds = @splat(if (place == from) run.timing.v0 else run.timing.v1);
            duration = (ends[1] - ends[0]) / speeds[0];
        } else continue;
        const change = shape.pieces[j].direction(1).scale(speeds[1]).sub(shape.pieces[j].direction(0).scale(speeds[0]));
        g.* = change.norm() < gentle_mps and duration < short_s;
    }
    const Cut = struct { s: f64, joint: Joint };
    var cuts: std.ArrayList(Cut) = .empty;
    for (gentle[0 .. gentle.len - 1], gentle[1..], shape.starts[base + 1 .. base + gentle.len]) |g0, g1, s| if (s > from and s < to and !g0 and !g1) try cuts.append(scratch, .{ .s = s, .joint = if (shape.pieces[0] == .cubic) .velocity else .acceleration });
    for (heights[1 .. heights.len - 1]) |s| try cuts.append(scratch, .{ .s = s + from, .joint = if (gentle[shape.piece(s + from) - base]) .velocity else .smooth });
    // In order, a place at a joint after the joint, whose cut it is.
    std.mem.sort(Cut, cuts.items, {}, struct {
        fn lessThan(_: void, l: Cut, r: Cut) bool {
            return l.s < r.s or (l.s == r.s and l.joint != .smooth and r.joint == .smooth);
        }
    }.lessThan);
    var t0 = run.start;
    var joint = if (first == .smooth and gentle[0]) .velocity else first;
    var s0 = from;
    for (0..cuts.items.len + 1) |k| {
        if (k > 0 and k < cuts.items.len and cuts.items[k].joint == .smooth and cuts.items[k].s == cuts.items[k - 1].s) continue;
        const s1 = if (k < cuts.items.len) cuts.items[k].s else to;
        const t1 = if (k < cuts.items.len) run.start + run.timing.time(s1 - from) else run.start + run.timing.duration;
        if (t1 > t0) {
            // A gentle corner's arc is run on its legs: the one before its place, and the one after.
            var piece = shape.piece((s0 + s1) / 2);
            if (gentle[piece - base]) piece = if ((s0 + s1) / 2 < shape.starts[piece] + shape.middles[piece]) piece - 1 else piece + 1;
            const runs_on = .{ piece > base and gentle[piece - 1 - base], piece + 1 - base < gentle.len and gentle[piece + 1 - base] };
            try out.append(scratch, .{ .t0 = t0, .t1 = t1, .joint = joint, .side = .{ .piece = piece, .runs_on = runs_on } });
            t0 = t1;
            s0 = s1;
            if (k < cuts.items.len) joint = cuts.items[k].joint;
        } else joint = .velocity;
    }
}

/// Each stretch of a run cut, its knots made as written; the knot it ends at returned.
fn cutRun(b: *Builder, i: usize, p: *Prepared, before: ?Knot) Error!Knot {
    var last = before;
    for (p.stretches, 0..) |*s, k| {
        const own = p.run.knot(s.t0, s.side);
        s.a = if (last) |l| switch (s.joint) {
            .smooth => l,
            .acceleration => .{ .t = l.t, .pos = l.pos, .vel = l.vel, .acc = own.acc },
            .velocity => .{ .t = l.t, .pos = l.pos, .vel = own.vel, .acc = own.acc },
        } else own;
        s.b = p.run.knot(s.t1, s.side);
        if (k + 1 == p.stretches.len) {
            if (p.snap) |at| s.b.pos = at;
            if (p.rest) {
                s.b.vel = zero;
                s.b.acc = zero;
            }
        }
        if (last != null and !std.meta.eql(s.a, last.?)) try b.take(i, 1);
        s.cuts = try cut(b, i, .{ .run = .{ .run = &p.run, .stretch = s } });
        try b.take(i, s.cuts.len);
        last = s.b;
    }
    return last.?;
}

/// What a stretch is cut from: a piece of a through, or a stretch of a run.
const Source = union(enum) {
    through: struct { solved: *const Solved, piece: usize },
    run: struct { run: *const motion.Run, stretch: *const Stretch },

    fn built(self: Source, t: f64) trajectory.State {
        return switch (self) {
            .through => |th| th.solved.at(th.piece, (t - th.solved.times[th.piece]) / (th.solved.times[th.piece + 1] - th.solved.times[th.piece])),
            .run => |r| r.run.state(t, r.stretch.side),
        };
    }

    /// The knot at the fraction u of it, its own knots at its ends.
    fn point(self: Source, u: f64) Knot {
        switch (self) {
            .through => |th| {
                if (u == 0) return th.solved.knot(th.piece);
                if (u == 1) return th.solved.knot(th.piece + 1);
                const q = th.solved.at(th.piece, u);
                const t0 = th.solved.times[th.piece];
                return .{ .t = t0 + (th.solved.times[th.piece + 1] - t0) * u, .pos = q.pos, .vel = q.vel, .acc = q.acc };
            },
            .run => |r| {
                if (u == 0) return r.stretch.a;
                if (u == 1) return r.stretch.b;
                return r.run.knot(r.stretch.t0 + (r.stretch.t1 - r.stretch.t0) * u, r.stretch.side);
            },
        }
    }
};

/// A stretch cut by halving, level by level, the pieces that need it: each piece whose knots' quintic misses the
/// tolerance of the built motion; once none does, each piece whose knots' bound of the receiver's domain fails, as
/// far as halving brings it nearer. Where the built motion leaves the domain, the pieces it has then, the build
/// marked out of the domain. Where its pieces end, as fractions of it.
fn cut(b: *Builder, i: usize, source: Source) Error![]const f64 {
    const Read = enum { holds, finer, unbounded };
    const Piece = struct { to: f64, read: ?Read = null };
    var pieces: std.ArrayList(Piece) = .empty;
    try pieces.append(b.scratch, .{ .to = 1 });
    var next: std.ArrayList(Piece) = .empty;
    const first = source.point(0);
    var left = false;
    if (outside(first.pos, first.vel, first.acc)) |reason| {
        b.mark(i, first.t, reason);
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
                    .through => |t| b.fail(try b.diags.arena.print("segments[{d}].through.places[{d}]", .{ i, t.piece }), "the path to this place cannot be stored: its velocity, acceleration or jerk is not finite", .{}),
                    .run => b.fail(try b.path(i, ""), "the path of this segment cannot be stored: its velocity, acceleration or jerk is not finite", .{}),
                },
                .leaves => |at| blk: {
                    b.mark(i, at.time, at.reason);
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
            if (failing == 0 or !(failing < unbounded[0])) break;
            unbounded = .{ unbounded[1], failing };
        }
        const halved: Read = if (finer) .finer else .unbounded;
        next.clearRetainingCapacity();
        from = 0;
        for (pieces.items) |p| {
            if (p.read == halved) try next.appendSlice(b.scratch, &.{ .{ .to = (from + p.to) / 2 }, .{ .to = p.to } }) else try next.append(b.scratch, p);
            from = p.to;
        }
        if (b.count + next.items.len > max_knots) return b.fail(try b.path(i, ""), "the path needs more knots than the {d} a PHT holds", .{max_knots});
        std.mem.swap(std.ArrayList(Piece), &pieces, &next);
    }
    const ends = try b.scratch.alloc(f64, pieces.items.len);
    for (ends, pieces.items) |*end, p| end.* = p.to;
    return ends;
}

const Within = union(enum) {
    holds,
    finer,
    /// The domain's bound between its knots fails.
    unbounded,
    /// A quintic whose rates are not finite.
    unstorable,
    leaves: struct { time: f64, reason: trajectory.Error },
};

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
        if (outside(s.pos, s.vel, s.acc)) |reason| return .{ .leaves = leaving(source, in, t, reason) };
        in = t;
        if (!(q.pos.sub(s.pos).norm() <= tolerance_m)) finer = true;
    }
    if (outside(z.pos, z.vel, z.acc)) |reason| return .{ .leaves = leaving(source, in, z.t, reason) };
    if (finer) return .finer;
    trajectory.checkKnot(&.{ a, z }, 1) catch |e| if (e == error.PathOutOfRange) return .unbounded;
    return .holds;
}

/// Where the built motion leaves the domain between a time it is in it and a later one it is not: by halving, the
/// first time found out of it, and the bound it breaks there.
fn leaving(source: Source, in: f64, out: f64, reason: trajectory.Error) @FieldType(Within, "leaves") {
    var low = in;
    var high = out;
    var why = reason;
    while (true) {
        const mid = (low + high) / 2;
        if (mid <= low or mid >= high) return .{ .time = high, .reason = why };
        const s = source.built(mid);
        if (outside(s.pos, s.vel, s.acc)) |broken| {
            high = mid;
            why = broken;
        } else low = mid;
    }
}

/// The bound of the receiver's domain a state breaks, if any.
fn outside(pos: Ecef, vel: Ecef, acc: Ecef) ?trajectory.Error {
    if (!trajectory.positionInRange(pos)) return error.PositionOutOfRange;
    if (!(vel.norm() <= trajectory.max_speed_mps)) return error.SpeedOutOfRange;
    if (!(acc.norm() <= trajectory.max_acceleration_mps2)) return error.AccelerationOutOfRange;
    return null;
}

/// A solved through: its knots' times, positions and heights, and the solve's velocities and accelerations.
const Solved = struct {
    times: []const f64,
    values: []const [through.axes]f64,
    states: []const through.Knot(through.axes),
    /// The velocity and acceleration it begins with, where the segment before leaves them.
    start: struct { vel: ?Ecef, acc: ?Ecef },
    /// The state it ends in: at rest, or a run's first.
    end: ?Knot,
    /// For each stretch between two places, where its pieces end, as fractions of it: the last at 1.
    cuts: [][]const f64,

    /// The knot at place k, the segment's start 0: at the place's position exactly, in the state held there where
    /// one is, or the path's.
    fn knot(self: *const Solved, k: usize) Knot {
        const t = self.times[k];
        const pos = Ecef.fromArray(self.values[k][0..3].*);
        if (k == self.times.len - 1) if (self.end) |e| return .{ .t = t, .pos = pos, .vel = e.vel, .acc = e.acc };
        var p: [through.axes]frame.Jet = undefined;
        for (&p, self.values[k], self.states[k].velocity, self.states[k].acceleration) |*axis, value, first, second| {
            axis.* = .{ .value = value, .first = first, .second = second };
        }
        const q = lifted4(p);
        if (k == 0) return .{ .t = t, .pos = pos, .vel = self.start.vel orelse q.vel, .acc = self.start.acc orelse q.acc };
        return .{ .t = t, .pos = pos, .vel = q.vel, .acc = q.acc };
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
        return lifted4(p);
    }
};

/// The path at the track's state and the height's: P lifted along its normal to the height h*.
fn lifted4(p: [through.axes]frame.Jet) trajectory.State {
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

fn solveThrough(b: *Builder, i: usize, before: State, visits: []const model.Visit, rest: bool, held_end: ?Knot) Error!Solved {
    const plan = b.plan;
    const n = visits.len + 1;
    const times = try b.scratch.alloc(f64, n);
    const values = try b.scratch.alloc([through.axes]f64, n);
    times[0] = before.time;
    values[0] = .{ before.pos.x, before.pos.y, before.pos.z, before.height };
    for (visits, times[1..], values[1..]) |visit, *t, *v| {
        const place = &plan.places[visit.place];
        t.* = visit.time;
        v.* = .{ place.ecef.x, place.ecef.y, place.ecef.z, place.height };
    }
    // The height held at P's own rates where a state is held.
    const start: frame.Frame = .at(frame.positionJet(before.pos, before.vel orelse zero, before.acc orelse zero));
    const end: ?Knot = if (rest) atRest(times[n - 1], Ecef.fromArray(values[n - 1][0..3].*)) else held_end;
    var held: through.Held(through.axes) = .{
        .velocity = if (before.vel) |v| .{ v.x, v.y, v.z, start.height.first } else null,
        .acceleration = if (before.acc) |a| .{ a.x, a.y, a.z, start.height.second } else null,
        .end = null,
    };
    if (end) |e| {
        const local: frame.Frame = .at(frame.positionJet(e.pos, e.vel, e.acc));
        held.end = .{ .velocity = .{ e.vel.x, e.vel.y, e.vel.z, local.height.first }, .acceleration = .{ e.acc.x, e.acc.y, e.acc.z, local.height.second } };
    }
    return switch (try through.solve(through.axes, b.scratch, times, values, held)) {
        .solved => |states| .{ .times = times, .values = values, .states = states, .start = .{ .vel = before.vel, .acc = before.acc }, .end = end, .cuts = try b.scratch.alloc([]const f64, n - 1) },
        .unsettled => |pieces| {
            for (pieces) |piece| try b.diags.err(.invalid_segment, try b.diags.arena.print("segments[{d}].through.places[{d}]", .{ i, piece }), "the path to this place cannot be solved in double precision: the gaps between the times about it differ too much", .{});
            return error.InvalidInput;
        },
    };
}
