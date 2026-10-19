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
const source = @import("source.zig");
const model = @import("plan.zig").model;
const frame = @import("frame.zig");
const check = @import("check.zig");
const path = @import("path.zig");

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
    broken: []const check.Stretch,
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

pub const Error = std.Io.Writer.Error || error{OutOfMemory};

/// `sample_count` at least 2: so many samples evenly over the path, besides one on each side of every knot, each
/// written as it is read.
pub fn write(allocator: std.mem.Allocator, w: *std.Io.Writer, built: source.Result, sample_count: usize) Error!void {
    const knots = built.trajectory.knots;
    const duration = built.trajectory.duration();
    // The path's length to each knot.
    const distances = try allocator.alloc(f64, knots.len);
    defer allocator.free(distances);
    distances[0] = 0;
    for (distances[1..], knots[0 .. knots.len - 1], knots[1..], 0..) |*d, k0, k1, i| d.* = distances[i] + distance(k0, k1, k1.t);
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.beginObject();
    try jw.objectField("distance3d");
    try jw.write(distances[knots.len - 1]);
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
        .broken = c.broken,
    });
    try jw.endArray();

    // The samples in the order of time, the knots' two sides with the even ones.
    try jw.objectField("samples");
    try jw.beginArray();
    var walk: Walk = .{ .knots = knots, .distances = distances, .datum = built.plan.altitude };
    const intervals: f64 = @floatFromInt(sample_count - 1);
    var knot: usize = 0;
    var even: usize = 0;
    var previous: ?Sample = null;
    while (knot < knots.len or even < sample_count) {
        const at_even = duration * @as(f64, @floatFromInt(even)) / intervals;
        var requests: [2]Request = undefined;
        var count: usize = 1;
        if (knot < knots.len and (even == sample_count or knots[knot].t <= at_even)) {
            requests = .{ .{ .time_s = knots[knot].t, .before = true }, .{ .time_s = knots[knot].t } };
            // The two knots of a step share their time, and its two sides are read at the first.
            count = if (knot > 0 and knots[knot - 1].t == knots[knot].t) 0 else 2;
            knot += 1;
        } else {
            requests[0] = .{ .time_s = at_even };
            even += 1;
        }
        for (requests[0..count]) |request| {
            const value = walk.sample(request);
            if (previous) |p| if (std.meta.eql(p, value)) continue;
            try jw.write(value);
            previous = value;
        }
    }
    try jw.endArray();
    try jw.endObject();
}

/// A sample at a time, on the piece that ends there or on the one that begins there.
const Request = struct { time_s: f64, before: bool = false };

/// The pieces the samples are read on, and over EGM96 the geoid's cells.
const Walk = struct {
    knots: []const Knot,
    distances: []const f64,
    datum: model.Altitude,
    cells: frame.Cells = .{},

    fn sample(self: *Walk, request: Request) Sample {
        const knots = self.knots;
        const after = if (request.before) std.sort.partitionPoint(Knot, knots, request.time_s, before) else std.sort.partitionPoint(Knot, knots, request.time_s, atOrBefore);
        const piece = std.math.clamp(after, 1, knots.len - 1) - 1;
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
            .distance3d = self.distances[piece] + distance(k0, k1, request.time_s),
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

/// The length of the path from k0 to the time t of its piece to k1, by five-point Gauss-Legendre; nothing across the
/// two knots of a step, which share their time.
fn distance(k0: Knot, k1: Knot, t: f64) f64 {
    const nodes = [_]f64{ 0, -0.5384693101056831, 0.5384693101056831, -0.9061798459386640, 0.9061798459386640 };
    const weights = [_]f64{ 0.5688888888888889, 0.4786286704993665, 0.4786286704993665, 0.2369268850561891, 0.2369268850561891 };
    const span = t - k0.t;
    if (span == 0) return 0;
    var sum: f64 = 0;
    for (nodes, weights) |node, weight| sum += weight * trajectory.between(k0, k1, k0.t + (node + 1) * span / 2).vel.norm();
    return sum * span / 2;
}
