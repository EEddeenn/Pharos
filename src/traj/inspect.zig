//! A built path as a caller reads it: its events, each with where in the plan it comes from, its segments, and
//! samples of its motion, read off the knots that its PHT holds.
const std = @import("std");
const shared = @import("shared");
const coord = shared.core.coord;
const trajectory = shared.trajectory;
const Knot = trajectory.Knot;
const source = @import("source.zig");
const model = @import("plan.zig").model;
const frame = @import("frame.zig");

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
    speed: f64,
    course: ?f64,
    velocityEcef: [3]f64,
    accelerationEcef: [3]f64,
};

pub const Segment = struct {
    kind: model.Kind,
    id: ?[]const u8,
    start: f64,
    end: f64,
};

pub const Sample = struct {
    time: f64,
    distance: f64,
    latitude: f64,
    longitude: f64,
    altitude: f64,
    speed: f64,
    horizontalSpeed: f64,
    forwardSpeed: f64,
    up: f64,
    acceleration: f64,
    forwardAcceleration: ?f64,
    jerk: f64,
    forwardJerk: ?f64,
    course: ?f64,
    turnRate: ?f64,
    lateralAcceleration: ?f64,
};

pub const Inspection = struct {
    distance: f64,
    duration: f64,
    events: []const Event,
    segments: []const Segment,
    samples: []const Sample,
};

pub const Error = error{OutOfMemory};

/// A sample at a time, on the piece that ends there or on the one that begins there.
const Request = struct { time_s: f64, before: bool = false };

/// `sample_count` at least 2: so many samples evenly over the path, besides one on each side of every knot.
pub fn of(arena: std.mem.Allocator, built: source.Result, sample_count: usize) Error!Inspection {
    const knots = built.trajectory.knots;
    const duration = built.trajectory.duration();
    const distances = try arena.alloc(f64, knots.len);
    distances[0] = 0;
    for (distances[1..], knots[0 .. knots.len - 1], knots[1..], 0..) |*d, k0, k1, i| d.* = distances[i] + distance(k0, k1, k1.t);

    const events = try arena.alloc(Event, built.plan.events.len);
    for (built.plan.events, events) |event, *out| {
        const time = if (event.segment) |s| if (event.visit) |v| built.plan.segments[s].motion.through.visits[v].time else built.ends[s] else 0;
        // Every event is at a knot: where two share its time, the one the segment before ends at.
        const knot = knots[std.sort.partitionPoint(Knot, knots, time, before)];
        const lla = coord.ecefToLla(knot.pos);
        const reading = frame.Reading.of(.{ .pos = knot.pos, .vel = knot.vel, .acc = knot.acc, .jerk = .{ .x = 0, .y = 0, .z = 0 } }, built.plan.altitude);
        out.* = .{
            .id = event.name,
            .time = time,
            .segment = event.segment,
            .place = event.visit,
            .latitude = lla.latDeg(),
            .longitude = lla.lonDeg(),
            .altitude = reading.altitude_m,
            .speed = reading.speed_mps,
            .course = reading.course_deg,
            .velocityEcef = knot.vel.toArray(),
            .accelerationEcef = knot.acc.toArray(),
        };
    }

    const segments = try arena.alloc(Segment, built.plan.segments.len);
    var start: f64 = 0;
    for (built.plan.segments, segments, built.ends) |segment, *out, end| {
        out.* = .{ .kind = segment.motion, .id = segment.id, .start = start, .end = end };
        start = end;
    }

    var requests: std.ArrayList(Request) = .empty;
    for (knots) |knot| try requests.appendSlice(arena, &.{ .{ .time_s = knot.t, .before = true }, .{ .time_s = knot.t } });
    const intervals: f64 = @floatFromInt(sample_count - 1);
    for (0..sample_count) |i| try requests.append(arena, .{ .time_s = duration * @as(f64, @floatFromInt(i)) / intervals });
    std.mem.sort(Request, requests.items, {}, requestBefore);
    var samples: std.ArrayList(Sample) = .empty;
    for (requests.items, 0..) |request, i| {
        if (i > 0 and std.meta.eql(requests.items[i - 1], request)) continue;
        const value = sample(knots, distances, built.plan.altitude, request);
        if (samples.items.len == 0 or !std.meta.eql(samples.items[samples.items.len - 1], value)) try samples.append(arena, value);
    }
    return .{
        .distance = distances[knots.len - 1],
        .duration = duration,
        .events = events,
        .segments = segments,
        .samples = samples.items,
    };
}

fn before(t: f64, k: Knot) bool {
    return k.t < t;
}

fn atOrBefore(t: f64, k: Knot) bool {
    return k.t <= t;
}

fn sample(knots: []const Knot, distances: []const f64, datum: model.Altitude, request: Request) Sample {
    const after = if (request.before) std.sort.partitionPoint(Knot, knots, request.time_s, before) else std.sort.partitionPoint(Knot, knots, request.time_s, atOrBefore);
    const piece = std.math.clamp(after, 1, knots.len - 1) - 1;
    const k0 = knots[piece];
    const k1 = knots[piece + 1];
    var state = trajectory.between(k0, k1, request.time_s);
    // At a knot, its state as the PHT holds it (rest as exact zeros), and the jerk of the piece on the side asked.
    for ([_]Knot{ k0, k1 }) |k| if (k.t == request.time_s) {
        state = .{ .pos = k.pos, .vel = k.vel, .acc = k.acc, .jerk = state.jerk };
    };
    const reading = frame.Reading.of(state, datum);
    const lla = coord.ecefToLla(state.pos);
    return .{
        .time = request.time_s,
        .distance = distances[piece] + distance(k0, k1, request.time_s),
        .latitude = lla.latDeg(),
        .longitude = lla.lonDeg(),
        .altitude = reading.altitude_m,
        .speed = reading.speed_mps,
        .horizontalSpeed = reading.horizontal_speed_mps,
        .forwardSpeed = reading.horizontal_speed_mps,
        .up = reading.climb_mps,
        .acceleration = reading.acceleration_mps2,
        .forwardAcceleration = reading.forward_acceleration_mps2,
        .jerk = reading.jerk_mps3,
        .forwardJerk = reading.forward_jerk_mps3,
        .course = reading.course_deg,
        .turnRate = reading.turn_rate_degps,
        .lateralAcceleration = reading.lateral_acceleration_mps2,
    };
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

fn requestBefore(_: void, left: Request, right: Request) bool {
    if (left.time_s != right.time_s) return left.time_s < right.time_s;
    return left.before and !right.before;
}
