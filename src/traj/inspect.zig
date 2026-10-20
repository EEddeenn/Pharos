//! A built path as a caller reads it, written as JSON straight to its output: its events, each with where in the
//! plan it comes from; its segments, with their length and the speed they end at over the ground, in the plan's
//! terms; each limit's check; and samples of its motion read off the knots its PHT holds, as the path moves at its
//! height.
const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const coord = core.coord;
const trajectory = shared.trajectory;
const Knot = trajectory.Knot;
const Scalar = trajectory.hermite.Scalar;
const source = @import("source.zig");
const model = @import("plan.zig").model;
const frame = @import("frame.zig");
const check = @import("check.zig");
const path = @import("path.zig");
const measure = @import("measure.zig");

pub const Event = struct {
    id: []const u8,
    time: f64,
    /// Where in the plan it comes from: its segment's position, and for a place of a through the place's position
    /// among the through's places; both null for the start.
    segment: ?usize,
    place: ?usize,
    latitude: f64,
    longitude: f64,
    altitude: f64,
    speed3d: f64,
    course: ?f64,
    velocityEcef: [3]f64,
    accelerationEcef: [3]f64,
};

pub const Segment = struct {
    kind: model.Kind,
    id: ?[]const u8,
    start: f64,
    end: f64,
    /// Its length over the ground and the speed over the ground it ends at, as the plan states them; the course it
    /// ends on, null below a millimetre a second.
    length: f64,
    endSpeed: f64,
    endCourse: ?f64,
};

pub const Check = struct {
    limit: usize,
    id: ?[]const u8,
    quantity: []const u8,
    max: ?f64,
    min: ?f64,
    holds: bool,
    worst: ?check.Worst,
    broken: Broken,
};

/// The stretches where a limit is broken, by their times: the segment each begins in is the finding's.
const Broken = struct {
    stretches: []const check.Stretch,

    pub fn jsonStringify(self: Broken, jw: anytype) !void {
        try jw.beginArray();
        for (self.stretches) |s| try jw.write(.{ .from = s.from, .to = s.to });
        try jw.endArray();
    }
};

/// The motion at a time, as it moves at its height: the limits' quantities, read as they read them.
pub const Sample = struct {
    time: f64,
    distance3d: f64,
    latitude: f64,
    longitude: f64,
    altitude: f64,
    speed3d: f64,
    horizontalSpeed: f64,
    climbRate: f64,
    acceleration3d: f64,
    forwardAcceleration: ?f64,
    lateralAcceleration: ?f64,
    verticalAcceleration: f64,
    jerk3d: f64,
    forwardJerk: ?f64,
    course: ?f64,
    turnRate: ?f64,
};

/// The path's length in space to each knot and to each sample, told once for a text its caller counts and then
/// writes.
pub const Lengths = struct {
    knots: []f64,
    samples: []f64,

    /// `sample_count` at least 2.
    pub fn of(allocator: std.mem.Allocator, built: source.Result, sample_count: usize) error{OutOfMemory}!Lengths {
        const knots = built.trajectory.knots;
        const to_knots = try allocator.alloc(f64, knots.len);
        errdefer allocator.free(to_knots);
        to_knots[0] = 0;
        for (to_knots[1..], knots[0 .. knots.len - 1], knots[1..], 0..) |*d, k0, k1, i| d.* = to_knots[i] + distance(k0, k1, k1.t);
        const first: Requests = .{ .knots = knots, .duration = built.trajectory.duration(), .sample_count = sample_count };
        var counting = first;
        var count: usize = 0;
        while (counting.next()) |_| count += 1;
        const to_samples = try allocator.alloc(f64, count);
        var requests = first;
        for (to_samples) |*d| {
            const request = requests.next().?;
            const piece = pieceAt(knots, request);
            const k1 = knots[piece + 1];
            d.* = if (request.time_s == k1.t) to_knots[piece + 1] else to_knots[piece] + distance(knots[piece], k1, request.time_s);
        }
        return .{ .knots = to_knots, .samples = to_samples };
    }

    pub fn deinit(self: Lengths, allocator: std.mem.Allocator) void {
        allocator.free(self.knots);
        allocator.free(self.samples);
    }
};

/// `sample_count` at least 2, the one `lengths` were told for: so many samples evenly over the path, besides one on
/// each side of every knot, each written as it is read.
pub fn write(w: *std.Io.Writer, built: source.Result, sample_count: usize, lengths: Lengths) std.Io.Writer.Error!void {
    const knots = built.trajectory.knots;
    const duration = built.trajectory.duration();
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();
    try jw.objectField("distance3d");
    try jw.write(lengths.knots[knots.len - 1]);
    try jw.objectField("duration");
    try jw.write(duration);

    try jw.objectField("events");
    try jw.beginArray();
    var cells: frame.Cells = .{};
    for (built.plan.events) |event| {
        const time = if (event.segment) |s| if (event.visit) |v| built.plan.segments[s].motion.through.visits[v].time else built.ends[s] else 0;
        // Every event is at a knot: where two share its time, the one the segment before ends at, read on its piece
        // (the start on the one it begins).
        const index = std.sort.partitionPoint(Knot, knots, time, before);
        const knot = knots[index];
        const piece = if (index > 0) [2]Knot{ knots[index - 1], knot } else [2]Knot{ knot, knots[1] };
        const lla = coord.ecefToLla(knot.pos);
        const cell = if (built.plan.altitude == .egm96) cells.of(piece[0], piece[1], knot.t, knot.pos) else null;
        const reading = frame.Reading.of(.{ .pos = knot.pos, .vel = knot.vel, .acc = knot.acc, .jerk = .{ .x = 0, .y = 0, .z = 0 } }, built.plan.altitude, cell);
        try jw.write(Event{
            .id = event.name,
            .time = time,
            .segment = event.segment,
            .place = event.visit,
            .latitude = lla.latDeg(),
            .longitude = lla.lonDeg(),
            .altitude = reading.altitude_m,
            .speed3d = reading.speed_mps,
            .course = reading.course_deg,
            .velocityEcef = knot.vel.toArray(),
            .accelerationEcef = knot.acc.toArray(),
        });
    }
    try jw.endArray();

    try jw.objectField("segments");
    try jw.beginArray();
    var start: f64 = 0;
    for (built.plan.segments, built.ends, built.lengths, built.end_speeds, 0..) |segment, end, length, speed, i| {
        // The knot it ends at: the next segment's first, or the path's last.
        const last = if (i + 1 < built.first_knots.len) knots[built.first_knots[i + 1]] else knots[knots.len - 1];
        const reading = frame.Reading.of(.{ .pos = last.pos, .vel = last.vel, .acc = last.acc, .jerk = .{ .x = 0, .y = 0, .z = 0 } }, .ellipsoid, null);
        try jw.write(Segment{
            .kind = segment.motion,
            .id = segment.id,
            .start = start,
            .end = end,
            .length = length,
            .endSpeed = speed,
            .endCourse = if (speed >= frame.moving_mps) reading.course_deg else null,
        });
        start = end;
    }
    try jw.endArray();

    try jw.objectField("checks");
    try jw.beginArray();
    for (built.plan.limits, built.checks, 0..) |limit, c, i| try jw.write(Check{
        .limit = i,
        .id = limit.id,
        .quantity = model.Quantity.words.get(limit.quantity),
        .max = limit.max,
        .min = limit.min,
        .holds = c.holds,
        .worst = c.worst,
        .broken = .{ .stretches = c.broken },
    });
    try jw.endArray();

    try jw.objectField("samples");
    try jw.beginArray();
    var walk: Walk = .{ .knots = knots, .datum = built.plan.altitude };
    var requests: Requests = .{ .knots = knots, .duration = duration, .sample_count = sample_count };
    var previous: ?Sample = null;
    for (lengths.samples) |distance3d| {
        const value = walk.sample(requests.next().?, distance3d);
        if (previous) |p| if (std.meta.eql(p, value)) continue;
        try jw.write(value);
        previous = value;
    }
    try jw.endArray();
    try jw.endObject();
}

/// A sample at a time, on the piece that ends there or on the one that begins there.
const Request = struct { time_s: f64, before: bool = false };

/// The samples in the order of time, the knots' two sides with the even ones.
const Requests = struct {
    knots: []const Knot,
    duration: f64,
    sample_count: usize,
    knot: usize = 0,
    even: usize = 0,
    /// A knot's side after it, the next to read.
    after: ?f64 = null,

    fn next(self: *Requests) ?Request {
        if (self.after) |t| {
            self.after = null;
            return .{ .time_s = t };
        }
        const intervals: f64 = @floatFromInt(self.sample_count - 1);
        while (self.knot < self.knots.len or self.even < self.sample_count) {
            const at_even = self.duration * @as(f64, @floatFromInt(self.even)) / intervals;
            if (self.knot < self.knots.len and (self.even == self.sample_count or self.knots[self.knot].t <= at_even)) {
                const t = self.knots[self.knot].t;
                self.knot += 1;
                // The two knots of a step share their time, and its two sides are read at the first.
                if (self.knot > 1 and self.knots[self.knot - 2].t == t) continue;
                self.after = t;
                return .{ .time_s = t, .before = true };
            }
            self.even += 1;
            return .{ .time_s = at_even };
        }
        return null;
    }
};

/// The position of the first knot of the piece a request is read on.
fn pieceAt(knots: []const Knot, request: Request) usize {
    const after = if (request.before) std.sort.partitionPoint(Knot, knots, request.time_s, before) else std.sort.partitionPoint(Knot, knots, request.time_s, atOrBefore);
    return std.math.clamp(after, 1, knots.len - 1) - 1;
}

/// The pieces the samples are read on, and over EGM96 the geoid's cells.
const Walk = struct {
    knots: []const Knot,
    datum: model.Altitude,
    cells: frame.Cells = .{},

    fn sample(self: *Walk, request: Request, distance3d: f64) Sample {
        const knots = self.knots;
        const piece = pieceAt(knots, request);
        const k0 = knots[piece];
        const k1 = knots[piece + 1];
        var state = trajectory.between(k0, k1, request.time_s);
        // On a piece shorter than `path.short_s` the velocity and acceleration go evenly from its knots' to its
        // knots', the jerk their change over its time, as the limits read it.
        const h = k1.t - k0.t;
        if (h < path.short_s) {
            const u = (request.time_s - k0.t) / h;
            state.vel = k0.vel.add(k1.vel.sub(k0.vel).scale(u));
            state.acc = k0.acc.add(k1.acc.sub(k0.acc).scale(u));
            state.jerk = k1.acc.sub(k0.acc).scale(1 / h);
        }
        // At a knot, its state as the PHT holds it (rest as exact zeros), and the jerk of the piece on the side asked.
        for ([_]Knot{ k0, k1 }) |k| if (k.t == request.time_s) {
            state = .{ .pos = k.pos, .vel = k.vel, .acc = k.acc, .jerk = state.jerk };
        };
        const reading = frame.Reading.of(state, self.datum, if (self.datum == .egm96) self.cells.of(k0, k1, request.time_s, state.pos) else null);
        const lla = coord.ecefToLla(state.pos);
        return .{
            .time = request.time_s,
            .distance3d = distance3d,
            .latitude = lla.latDeg(),
            .longitude = lla.lonDeg(),
            .altitude = reading.altitude_m,
            .speed3d = reading.speed_mps,
            .horizontalSpeed = reading.horizontal_speed_mps,
            .climbRate = reading.climb_mps,
            .acceleration3d = reading.acceleration_mps2,
            .forwardAcceleration = reading.forward_acceleration_mps2,
            .lateralAcceleration = reading.lateral_acceleration_mps2,
            .verticalAcceleration = reading.vertical_acceleration_mps2,
            .jerk3d = reading.jerk_mps3,
            .forwardJerk = reading.forward_jerk_mps3,
            .course = reading.course_deg,
            .turnRate = reading.turn_rate_degps,
        };
    }
};

fn before(t: f64, k: Knot) bool {
    return k.t < t;
}

fn atOrBefore(t: f64, k: Knot) bool {
    return k.t <= t;
}

/// The length of the path from k0 to the time t of its piece to k1, a length told; nothing across the two knots of a
/// step, which share their time.
fn distance(k0: Knot, k1: Knot, t: f64) f64 {
    if (t == k0.t) return 0;
    return measure.told(Span.of(k0, k1, t));
}

/// The stored path from k0 over its piece to k1, up to a time of it, by the fraction of that span: its speed by the
/// fraction, and that speed's rate.
const Span = struct {
    coefficients: [3]Scalar.Quintic,
    /// The fraction of the piece it ends at.
    end: f64,

    fn of(k0: Knot, k1: Knot, t: f64) Span {
        return .{ .coefficients = trajectory.coefficients(k0, k1), .end = (t - k0.t) / (k1.t - k0.t) };
    }

    pub fn speed(self: Span, u: f64) [2]f64 {
        var rate: [3]f64 = undefined;
        var second: [3]f64 = undefined;
        for (self.coefficients, &rate, &second) |c, *r, *s| {
            r.* = Scalar.evaluate(1, c, self.end * u) * self.end;
            s.* = Scalar.evaluate(2, c, self.end * u) * self.end * self.end;
        }
        const v: coord.Ecef = .fromArray(rate);
        const value = v.norm();
        return .{ value, v.dot(.fromArray(second)) / value };
    }
};
