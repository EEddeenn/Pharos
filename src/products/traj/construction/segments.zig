//! Construct each segment's motion from the state it begins in.
//!
//! A stay is a knot at rest at its end. A through is solved (`through.zig`) on four axes: the ECEF path P of least
//! jerk gives the horizontal track, and the height h* of least jerk through the places' heights (ellipsoidal) is its
//! fourth axis, held where P is held, at P's own rate of height. The path is the track at that height,
//! Q = P + (h* - h_P) up, with h_P and up the height and the normal of P: it passes every place, and where the
//! segment begins it has the state the segment before left; before a straight, a turn or an along it ends in that
//! segment's first state. Those three are runs: a ground track run by the speed's step at a height.
const std = @import("std");
const diagnostics = @import("base/diagnostics");
const geoid = @import("domain/earth/geoid/model");
const trajectory = @import("domain/trajectory/trajectory");
const hermite = @import("domain/trajectory/hermite");
const polynomial = @import("base/math/polynomial");
const model = @import("products/traj/input/model");
const frame = @import("products/traj/motion/geometry/frame");
const through = @import("products/traj/motion/geometry/through");
const track = @import("products/traj/motion/geometry/track");
const guide = @import("products/traj/motion/geometry/guide");
const motion = @import("products/traj/motion/profile");
const measure = @import("products/traj/limits/measure");
const earth_constants = @import("domain/earth/constants");
const angles = @import("base/math/angles");

const Ecef = @import("domain/earth/coordinates").Ecef;
const Number = @import("base/text/number").Number;
const Range = @import("base/math/range").Range;

const Diagnostics = diagnostics.Diagnostics;
const Knot = trajectory.Knot;
const Scalar = hermite.Scalar;

/// The construction budget, including knots added at joins and by adaptive sampling.
pub const max_knots: usize = 1 << 22;

/// A piece of the stored path shorter than this carries its knots' rounding as motion: it is read at its knots
/// alone, and no gentle corner's arc is built as one.
pub const short_s: f64 = 1e-2;
/// Within this angle of the point opposite where a straight begins (the flattening's share of a half turn), the
/// geodesics from it part: several reach a place there.
const parting_deg = 180 * (1 - earth_constants.wgs_axis_b / earth_constants.wgs_axis_a);

pub const Error = diagnostics.InputError;

pub const Outside = struct {
    segment: usize,
    time: f64,
    reason: trajectory.DomainError,

    pub fn mark(outside: *?Outside, i: usize, time: f64, reason: trajectory.DomainError) void {
        if (outside.* == null or time < outside.*.?.time) outside.* = .{ .segment = i, .time = time, .reason = reason };
    }
};

const zero: Ecef = .{ .x = 0, .y = 0, .z = 0 };

/// The state a segment begins in.
pub const State = struct {
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
pub const Joint = enum { smooth, acceleration, velocity };

pub const Span = struct {
    from_s: f64,
    to_s: f64,
    joint: Joint,
    side: motion.Side,
};

pub const PreparedRun = struct {
    motion: motion.Run,
    spans: []const Span,
};

pub const ReadyRun = struct { prepared: PreparedRun, end: State };

pub const Builder = struct {
    plan: *const model.Plan,
    scratch: std.mem.Allocator,
    diags: *Diagnostics,
    shapes: []?guide.Shape,
    outside: *?Outside,

    pub fn init(scratch: std.mem.Allocator, plan: *const model.Plan, diags: *Diagnostics, outside: *?Outside) Error!Builder {
        const shapes = try scratch.alloc(?guide.Shape, plan.guides.len);
        @memset(shapes, null);
        return .{ .plan = plan, .scratch = scratch, .diags = diags, .shapes = shapes, .outside = outside };
    }

    /// A time that must come after the segment's start: where a time before follows from a speed, the plan's text
    /// cannot tell it.
    pub fn after(self: *Builder, i: usize, key: []const u8, time: f64, begin: f64) Error!void {
        // The time it begins at follows from a length and a speed: written as a number, not as a bound of the text.
        const range: Range = .{ .min = begin, .open_min = true };
        if (!range.holds(time)) return fail(self.diags, try path(self.diags, i, key), "must be above {f}, got {f}", .{ Number{ .value = begin, .apart = time }, Number{ .value = time, .outside = range } });
    }

    /// A segment's end within the longest a trajectory lasts.
    pub fn endsInTime(self: *Builder, i: usize, end: f64) Error!void {
        if (end > trajectory.max_duration_s) return fail(self.diags, try path(self.diags, i, ""), "ends {f} s from the start, and a trajectory lasts at most {d} s", .{ Number{ .value = end, .outside = .{ .max = trajectory.max_duration_s } }, trajectory.max_duration_s });
    }

    pub fn spanEnd(self: *Builder, i: usize, span: model.Span, begin: f64) Error!f64 {
        return switch (span) {
            .duration => |length| blk: {
                const end = begin + length;
                if (!(end > begin)) return fail(self.diags, try path(self.diags, i, "for"), "must end the {s} after it begins at {f} s, got an end at {f} s", .{ model.Kind.words.get(self.plan.segments[i].motion), Number{ .value = begin }, Number{ .value = end } });
                try self.endsInTime(i, end);
                break :blk end;
            },
            .until => |t| blk: {
                try self.after(i, "time", t, begin);
                break :blk t;
            },
        };
    }

    fn shape(self: *Builder, index: usize) Error!*const guide.Shape {
        if (self.shapes[index] == null) {
            const g = self.plan.guides[index];
            switch (try guide.build(self.scratch, self.plan.places, g)) {
                .shape => |s| self.shapes[index] = s,
                .fault => |fault| {
                    const kind = @tagName(g.shape);
                    switch (fault) {
                        .together => |p| return fail(self.diags, try self.diags.arena.print("guides[{d}].{s}.places[{d}]", .{ index, kind, p }), "is at the point of the place before it", .{}),
                        .corner => |c| return fail(self.diags, try self.diags.arena.print("guides[{d}].{s}.places[{d}]", .{ index, kind, c.place }), "the corner here needs {f} m of each leg to be rounded by the radius, and the leg to places[{d}] is {f} m", .{ Number{ .value = c.takes }, c.other, Number{ .value = c.leg } }),
                        .unsettled => |p| return fail(self.diags, try self.diags.arena.print("guides[{d}].{s}.places[{d}]", .{ index, kind, p }), "the path from here passes too near the geocentre for its ground track to be found", .{}),
                    }
                },
            }
        }
        return &self.shapes[index].?;
    }
};

/// A piece of a through by the fraction of it: its foot's speed over the ground by that fraction, and that speed's
/// rate, of its track P, whose foot is the path's (the height moves the path along the ellipsoid's normal).
const ThroughPiece = struct {
    solved: *const Solved,
    piece: usize,

    pub fn speed(self: ThroughPiece, u: f64) [2]f64 {
        const q = self.solved.trackAt(self.piece, u);
        return track.footSpeed(q[0], q[1], q[2]);
    }
};

const Ground = union(enum) {
    track: track.Track,
    /// Its length follows from the timing: built only after the end time is checked.
    unrun: struct { from: track.Node, curvature: f64 },
    guide: struct { shape: *const guide.Shape, from: f64, to: f64, joint: Joint, goes_on: bool },
};

/// A corner whose arc would change the velocity by less than this, and last less than `short_s`, steps the velocity
/// at its place instead: such an arc is a piece too short for a PHT's knots.
const gentle_mps: f64 = 1e-4;

/// A solved through: its knots' times, positions and heights, and the solve's velocities and accelerations.
pub const Solved = struct {
    times: []const f64,
    values: []const [through.axes]f64,
    states: []const through.Knot(through.axes),
    /// The velocity and acceleration it begins with, where the segment before leaves them.
    start: struct { vel: ?Ecef, acc: ?Ecef },
    /// The state it ends in: at rest, or a run's first.
    end: ?struct { vel: Ecef, acc: Ecef },

    /// The knot at place k, the segment's start 0: at the place's position exactly, in the state held there where
    /// one is, or the path's.
    pub fn knot(self: *const Solved, k: usize) Knot {
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
    pub fn at(self: *const Solved, k: usize, u: f64) motion.Sample {
        const h = self.times[k + 1] - self.times[k];
        var p: [through.axes]frame.Jet = undefined;
        for (&p, 0..) |*axis, a| {
            const m = Scalar.motion(self.quintic(k, a), h, u);
            axis.* = .{ .value = m.position, .first = m.velocity, .second = m.acceleration };
        }
        return lifted4(p);
    }

    /// The track P at the fraction u of piece k, with its first and second rates by that fraction.
    fn trackAt(self: *const Solved, k: usize, u: f64) [3]Ecef {
        var out: [3][3]f64 = undefined;
        for (0..3) |a| {
            const c = self.quintic(k, a);
            out[0][a] = polynomial.evaluate(f64, hermite.Float(f64), 0, c, u);
            out[1][a] = polynomial.evaluate(f64, hermite.Float(f64), 1, c, u);
            out[2][a] = polynomial.evaluate(f64, hermite.Float(f64), 2, c, u);
        }
        return .{ .fromArray(out[0]), .fromArray(out[1]), .fromArray(out[2]) };
    }

    /// Piece k's quintic on one axis, in its fraction.
    fn quintic(self: *const Solved, k: usize, a: usize) Scalar.Quintic {
        return Scalar.quintic(self.values[k][a], self.states[k].velocity[a], self.states[k].acceleration[a], self.values[k + 1][a], self.states[k + 1].velocity[a], self.states[k + 1].acceleration[a], self.times[k + 1] - self.times[k]);
    }
};

pub fn fail(diags: *Diagnostics, where: []const u8, comptime fmt: []const u8, args: anytype) Error {
    try diags.err(.invalid_segment, where, fmt, args);
    return error.InvalidInput;
}

pub fn path(diags: *Diagnostics, i: usize, key: []const u8) Error![]const u8 {
    return if (key.len == 0) diags.arena.print("segments[{d}]", .{i}) else diags.arena.print("segments[{d}].{s}", .{ i, key });
}

/// A through's length over the ground: its foot's speed over each piece between its places, a length told.
pub fn groundLength(s: *const Solved) f64 {
    var sum: f64 = 0;
    for (0..s.times.len - 1) |k| sum += measure.told(ThroughPiece{ .solved = s, .piece = k });
    return sum;
}

pub fn isRun(segment: model.Segment) bool {
    return switch (segment.motion) {
        .straight, .turn, .along => true,
        .stay, .through => false,
    };
}

pub fn atRest(t: f64, pos: Ecef) Knot {
    return .{ .t = t, .pos = pos, .vel = zero, .acc = zero };
}

pub fn knotOf(state: State) Knot {
    return .{ .t = state.time, .pos = state.pos, .vel = state.vel.?, .acc = state.acc.? };
}

/// The foot on the ellipsoid of a position.
pub fn footOf(pos: Ecef) Ecef {
    const local: frame.Frame = .at(frame.positionJet(pos, zero, zero));
    return .{
        .x = pos.x - local.height.value * local.up[0].value,
        .y = pos.y - local.height.value * local.up[1].value,
        .z = pos.z - local.height.value * local.up[2].value,
    };
}

pub fn placeState(plan: *const model.Plan, time: f64, index: usize) State {
    const place = &plan.places[index];
    return .{ .time = time, .pos = place.ecef, .vel = null, .acc = null, .height = place.height, .place = index, .foot = footOf(place.ecef), .tangent = null, .speed = null, .vertical = null };
}

pub fn startState(plan: *const model.Plan) State {
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

/// Prepare geometry and timing, then return the complete boundary state for the next segment.
pub fn prepare(b: *Builder, i: usize, before: State) Error!ReadyRun {
    const plan = b.plan;
    const segment = plan.segments[i];
    const scratch = b.scratch;
    const span_s = if (spanOf(segment)) |span| try b.spanEnd(i, span, before.time) - before.time else null;
    var foot = before.foot;
    var tangent = before.tangent;
    var ground: Ground = undefined;
    var end_place: ?usize = null;
    var timing: motion.Timing = undefined;
    var vertical: model.VerticalGoal = .{};
    var rest = false;
    switch (segment.motion) {
        .straight => |straight| {
            switch (straight) {
                .to => |to| {
                    const target = footOf(plan.places[to.place].ecef);
                    if (std.meta.eql(target, foot)) return fail(b.diags, try path(b.diags, i, "straight.to"), "is where the straight begins, or right above or below it", .{});
                    if (-track.normal(target).dot(track.normal(foot)) > @cos(angles.deg2rad(parting_deg))) return fail(b.diags, try path(b.diags, i, "straight.to"), "lies within {f} degrees of the point opposite where the straight begins, where several geodesics reach a place", .{Number{ .value = parting_deg }});
                    const geodesic = (try track.toward(scratch, foot, target)) orelse return fail(b.diags, try path(b.diags, i, "straight.to"), "no geodesic to this place could be found: it lies too nearly opposite where the straight begins", .{});
                    ground = .{ .track = geodesic };
                    tangent = geodesic.nodes[0].tangent;
                    timing = try fixedTiming(b, i, before.speed, geodesic.length, to.motion, span_s);
                    vertical.climb_mps = to.climb_mps;
                    end_place = to.place;
                    rest = fixedRest(to.motion);
                },
                .distance => |distance| {
                    if (distance.course_rad) |course| tangent = track.heading(foot, course);
                    timing = try fixedTiming(b, i, before.speed, distance.distance_m, distance.motion, span_s);
                    vertical = distance.vertical;
                    rest = fixedRest(distance.motion);
                },
                .timed => |timed| {
                    if (timed.course_rad) |course| tangent = track.heading(foot, course);
                    timing = timedTiming(before.speed, timed.motion.end_speed_mps, span_s.?);
                    vertical = timed.vertical;
                    rest = timed.motion.end_speed_mps == 0;
                },
            }
            if (straight != .to) ground = .{ .unrun = .{ .from = .{ .point = foot, .tangent = tangent.? }, .curvature = 0 } };
        },
        .turn => |turn| {
            const from: track.Node = .{ .point = foot, .tangent = tangent.? };
            switch (turn) {
                .radius => |radius| {
                    const curvature = 1 / radius.radius_m;
                    vertical = radius.vertical;
                    switch (radius.extent) {
                        .timed => |timed| {
                            ground = .{ .unrun = .{ .from = from, .curvature = curvature } };
                            timing = timedTiming(before.speed, timed.end_speed_mps, span_s.?);
                            rest = timed.end_speed_mps == 0;
                        },
                        .angular => |angular| {
                            const path_ = try turnGround(b, i, from, curvature, angular.end);
                            ground = path_.ground;
                            timing = try fixedTiming(b, i, before.speed, path_.length, angular.motion, span_s);
                            rest = fixedRest(angular.motion);
                        },
                    }
                },
                .steady => |steady| {
                    const speed = before.speed orelse steady.speed_mps.?;
                    const curvature = switch (steady.bend) {
                        .rate_radps => |rate| rate / speed,
                        .lateral_mps2 => |lateral| lateral / (speed * speed),
                    };
                    vertical = steady.vertical;
                    rest = steady.speed_mps == 0;
                    const duration = switch (steady.end) {
                        .span => blk: {
                            ground = .{ .unrun = .{ .from = from, .curvature = curvature } };
                            break :blk span_s.?;
                        },
                        .angular => |angular| blk: {
                            const path_ = try turnGround(b, i, from, curvature, angular);
                            ground = path_.ground;
                            break :blk path_.length / speed;
                        },
                    };
                    timing = .{ .v0 = speed, .v1 = speed, .duration = duration };
                },
            }
        },
        .along => |along| {
            const shape = try b.shape(along.guide);
            const g = plan.guides[along.guide];
            const continues = if (before.on) |on| on.guide == along.guide else false;
            const from = if (continues) before.on.?.length else shape.places[along.from];
            const to = shape.places[along.to];
            ground = .{ .guide = .{
                .shape = shape,
                .from = from,
                .to = to,
                .joint = if (!continues) .acceleration else if (shape.pieces[shape.piece(from)] == .arc) .smooth else .velocity,
                .goes_on = i + 1 < plan.segments.len and switch (plan.segments[i + 1].motion) {
                    .along => |next| next.guide == along.guide,
                    else => false,
                },
            } };
            const point = shape.ground(shape.piece(from), from, .{ false, false });
            if (!continues) foot = point.point;
            tangent = point.tangent;
            if (g.shape == .bezier or along.to == g.places.len - 1) end_place = g.places[along.to];
            timing = try fixedTiming(b, i, before.speed, to - from, along.motion, span_s);
            rest = fixedRest(along.motion);
        },
        .stay, .through => unreachable,
    }
    const end_time = before.time + timing.duration;
    if (!(end_time > before.time)) return fail(b.diags, try path(b.diags, i, ""), "must end after it begins at {f} s, and its length at its speeds takes no time", .{Number{ .value = before.time }});
    try b.endsInTime(i, end_time);
    var run: motion.Run = .{
        .start = before.time,
        .timing = timing,
        .ground = switch (ground) {
            .track => |g| .{ .track = g },
            .unrun => |u| .{ .track = try runTrack(b, i, u.from, u.curvature, timing.length()) },
            .guide => |p| .{ .guide = .{ .shape = p.shape, .from = p.from } },
        },
        .height = undefined,
    };
    var spans: std.ArrayList(Span) = .empty;
    switch (ground) {
        .guide => |p| {
            run.height = .{ .places = try profile(b, i, before, p.shape, p.from, p.to, timing.v0) };
            try alongSpans(scratch, &spans, &run, p.shape, p.from, p.to, p.joint, p.goes_on);
            // A polyline's velocity steps only at a corner whose arc takes no time or is gentle: the motion turns there
            // at once, and is held against the receiver's domain by the acceleration its arc takes at the speed there.
            switch (plan.guides[segment.motion.along.guide].shape) {
                .polyline => |radius| for (spans.items) |s| if (s.joint == .velocity) {
                    const v = timing.at(s.from_s - before.time).first;
                    if (!(v * v / radius <= trajectory.max_acceleration_mps2)) Outside.mark(b.outside, i, s.from_s, error.AccelerationOutOfRange);
                },
                .bezier => {},
            }
        },
        .track, .unrun => {
            const v = verticalOf(plan, before);
            // A run after a free start or a through takes its own climb from its start.
            const from: [3]f64 = if (before.speed == null) .{ v[0], vertical.climb_mps orelse 0, 0 } else v;
            const c1 = vertical.climb_mps orelse if (vertical.altitude_m != null or rest) 0 else from[1];
            const h1 = vertical.altitude_m orelse if (end_place) |e| plan.places[e].altitude else from[0] + timing.duration * (from[1] + c1) / 2;
            run.height = .{ .own = .{ .from = from, .to = .{ h1, c1 }, .duration = timing.duration } };
            const lines: []const f64 = if (plan.altitude == .egm96) try motion.crossings(scratch, &run.ground.track) else &.{};
            var t0 = before.time;
            for (0..lines.len + 1) |k| {
                const t1 = if (k < lines.len) before.time + timing.time(lines[k]) else end_time;
                if (!(t1 > t0)) continue;
                // A segment's acceleration may step where it begins; the geoid's grid lines step the velocity.
                try spans.append(scratch, .{ .from_s = t0, .to_s = t1, .joint = if (spans.items.len == 0) .acceleration else .velocity, .side = .{} });
                t0 = t1;
            }
            if (plan.altitude == .egm96) for (spans.items) |*s| {
                const n = track.normal(run.foot((s.from_s + s.to_s) / 2, .{}).point.point);
                const cell = try scratch.create(geoid.Cell);
                cell.* = .at(std.math.atan2(n.z, @sqrt(n.x * n.x + n.y * n.y)), std.math.atan2(n.y, n.x));
                s.side.cell = cell;
            };
        },
    }
    const last = spans.items[spans.items.len - 1];
    const end = run.knot(end_time, last.side);
    const end_foot = run.foot(end_time, last.side).point;
    const snap: ?Ecef = if (end_place) |e| plan.places[e].ecef else null;
    const at_foot = if (end_place) |e| footOf(plan.places[e].ecef) else end_foot.point;
    const height = switch (segment.motion) {
        .along => |a| plan.places[plan.guides[a.guide].places[a.to]].height,
        else => if (end_place) |e| plan.places[e].height else heightOf(end.pos),
    };
    return .{
        .prepared = .{ .motion = run, .spans = spans.items },
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
            .on = switch (ground) {
                .guide => |p| .{ .guide = segment.motion.along.guide, .length = p.to },
                .track, .unrun => null,
            },
        },
    };
}

pub fn solveThrough(b: *Builder, i: usize, before: State, visits: []const model.Visit, rest: bool, held_end: ?Knot) Error!Solved {
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
    var held: through.Held(through.axes) = .{};
    if (before.vel) |v| {
        const velocity: [through.axes]f64 = .{ v.x, v.y, v.z, start.height.first };
        held.start = if (before.acc) |a|
            .{ .state = .{ .velocity = velocity, .acceleration = .{ a.x, a.y, a.z, start.height.second } } }
        else
            .{ .velocity = velocity };
    }
    if (end) |e| {
        const local: frame.Frame = .at(frame.positionJet(e.pos, e.vel, e.acc));
        held.end = .{ .velocity = .{ e.vel.x, e.vel.y, e.vel.z, local.height.first }, .acceleration = .{ e.acc.x, e.acc.y, e.acc.z, local.height.second } };
    }
    return switch (try through.solve(through.axes, b.scratch, times, values, held)) {
        .solved => |states| .{ .times = times, .values = values, .states = states, .start = .{ .vel = before.vel, .acc = before.acc }, .end = if (end) |e| .{ .vel = e.vel, .acc = e.acc } else null },
        .unsettled => |pieces| {
            for (pieces) |piece| try b.diags.err(.invalid_segment, try b.diags.arena.print("segments[{d}].through.places[{d}]", .{ i, piece }), "the path to this place cannot be solved in double precision: the gaps between the times about it differ too much", .{});
            return error.InvalidInput;
        },
    };
}

fn heightOf(pos: Ecef) f64 {
    return frame.Frame.at(frame.positionJet(pos, zero, zero)).height.value;
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
        .egm96 => local.height.sub(geoid.Evaluator(frame.Jet, frame.Jet.Arithmetic).height(local.up)),
    };
    return .{ if (state.place) |p| plan.places[p].altitude else h.value, h.first, h.second };
}

fn fixedSpan(request: model.FixedMotion) ?model.Span {
    return switch (request) {
        .span => |span| span,
        else => null,
    };
}

fn spanOf(segment: model.Segment) ?model.Span {
    return switch (segment.motion) {
        .stay => |span| span,
        .through => null,
        .along => |along| fixedSpan(along.motion),
        .straight => |straight| switch (straight) {
            .to => |to| fixedSpan(to.motion),
            .distance => |distance| fixedSpan(distance.motion),
            .timed => |timed| timed.motion.span,
        },
        .turn => |turn| switch (turn) {
            .radius => |radius| switch (radius.extent) {
                .timed => |timed| timed.span,
                .angular => |angular| fixedSpan(angular.motion),
            },
            .steady => |steady| switch (steady.end) {
                .span => |span| span,
                .angular => null,
            },
        },
    };
}

fn fixedRest(request: model.FixedMotion) bool {
    return switch (request) {
        .end_speed_mps => |speed| speed == 0,
        else => false,
    };
}

/// The span was resolved before constructing the geometry, preserving the first numerical failure's source.
fn fixedTiming(b: *Builder, i: usize, v0_given: ?f64, length: f64, request: model.FixedMotion, span_s: ?f64) Error!motion.Timing {
    switch (request) {
        .keep_speed => return .{ .v0 = v0_given.?, .v1 = v0_given.?, .duration = length / v0_given.? },
        .end_speed_mps => |v1| {
            const v0 = v0_given orelse v1;
            return .{ .v0 = v0, .v1 = v1, .duration = 2 * length / (v0 + v1) };
        },
        .span => |span| {
            const duration = span_s.?;
            const v0 = v0_given orelse length / duration;
            const v1 = 2 * length / duration - v0;
            if (v1 < 0) {
                const until = span == .until;
                const begin = if (until) span.until - duration else 0;
                return fail(b.diags, try path(b.diags, i, if (until) "time" else "for"), "must be at most {f}, got {f}: over its {f} m from {f} m/s, any longer would end it below a speed of 0", .{ Number{ .value = begin + 2 * length / v0 }, Number{ .value = begin + duration }, Number{ .value = length }, Number{ .value = v0 } });
            }
            return .{ .v0 = v0, .v1 = v1, .duration = duration };
        },
    }
}

fn timedTiming(v0_given: ?f64, end_speed_mps: ?f64, duration: f64) motion.Timing {
    const v0 = v0_given orelse end_speed_mps.?;
    return .{ .v0 = v0, .v1 = end_speed_mps orelse v0, .duration = duration };
}

fn runTrack(b: *Builder, i: usize, from: track.Node, curvature: f64, length: f64) Error!track.Track {
    if (!(track.steps(curvature, length) <= max_knots)) return fail(b.diags, try path(b.diags, i, ""), "the path needs more than {d} knots", .{max_knots});
    return track.run(b.scratch, from, curvature, length);
}

fn turnGround(b: *Builder, i: usize, from: track.Node, curvature: f64, end: model.AngularEnd) Error!struct { ground: Ground, length: f64 } {
    return switch (end) {
        .by_rad => |angle| .{ .ground = .{ .unrun = .{ .from = from, .curvature = curvature } }, .length = angle / curvature },
        .onto_rad => |onto| blk: {
            const right = @mod(onto - track.azimuth(from), angles.two_pi);
            const angle = if (curvature > 0) (if (right == 0) angles.two_pi else right) else right - angles.two_pi;
            const turned = (try track.turning(b.scratch, from, curvature, angle, max_knots)) orelse return fail(b.diags, try path(b.diags, i, "turn.onto"), "the turn's course does not reach it within {d} knots", .{max_knots});
            break :blk .{ .ground = .{ .track = turned }, .length = turned.length };
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
    var held: through.Held(1) = .{};
    if (before.speed != null and v0 > 0) {
        const local: frame.Frame = .at(frame.positionJet(before.pos, before.vel orelse zero, before.acc orelse zero));
        const velocity: [1]f64 = .{if (before.vel != null) local.height.first / v0 else 0};
        held.start = if (before.acc != null)
            .{ .state = .{ .velocity = velocity, .acceleration = .{local.height.second / (v0 * v0)} } }
        else
            .{ .velocity = velocity };
    }
    return switch (try through.solve(1, b.scratch, lengths.items, heights.items, held)) {
        .solved => |knots| .{ .lengths = lengths.items, .heights = heights.items, .knots = knots },
        .unsettled => fail(b.diags, try path(b.diags, i, "along"), "the heights along this part of the guide cannot be solved in double precision: the gaps between its places differ too much", .{}),
    };
}

/// An along's spans: cut where its guide's pieces meet (a Bezier's joint may step the velocity, a polyline's
/// tangent point the acceleration) and at its heights' places, the first meeting the motion before by `first`;
/// `goes_on` where the next segment goes on along the guide. A part that takes no time (an arc too small for the
/// time's precision) is the step in velocity it makes; so is a gentle corner, its legs run on to its place, where the
/// velocity steps.
fn alongSpans(scratch: std.mem.Allocator, out: *std.ArrayList(Span), run: *const motion.Run, shape: *const guide.Shape, from: f64, to: f64, first: Joint, goes_on: bool) Error!void {
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
            try out.append(scratch, .{ .from_s = t0, .to_s = t1, .joint = joint, .side = .{ .piece = piece, .runs_on = runs_on } });
            t0 = t1;
            s0 = s1;
            if (k < cuts.items.len) joint = cuts.items[k].joint;
        } else joint = .velocity;
    }
}

/// The path at the track's state and the height's: P lifted along its normal to the height h*.
fn lifted4(p: [through.axes]frame.Jet) motion.Sample {
    const position: frame.Vector = p[0..3].*;
    const local: frame.Frame = .at(position);
    const lift = p[3].sub(local.height);
    var q: frame.Vector = undefined;
    for (&q, position, local.up) |*out, axis, normal| out.* = axis.add(lift.mul(normal));
    return .{
        .pos = .{ .x = q[0].value, .y = q[1].value, .z = q[2].value },
        .vel = .{ .x = q[0].first, .y = q[1].first, .z = q[2].first },
        .acc = .{ .x = q[0].second, .y = q[1].second, .z = q[2].second },
    };
}
