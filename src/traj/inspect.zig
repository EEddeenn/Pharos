const std = @import("std");
const source = @import("source.zig");
const solve = @import("solve.zig");
const plan = @import("plan.zig");
const model = plan.model;
const core = @import("shared").core;

pub const Report = struct {
    status: []const u8,
    feasible: bool,
    verified: bool,
    settled: bool,
    iterations: usize,
    work: usize,
    tier: []const u8,
    cells: usize,
    passes: usize,
    overruns: usize,
    objective: f64,
    maxViolation: f64,
    stationarity: f64,
};

pub const Event = struct {
    id: []const u8,
    index: usize,
    time: f64,
    latitude: f64,
    longitude: f64,
    altitude: f64,
    speed: f64,
    course: ?f64,
    velocityEcef: [3]f64,
    accelerationEcef: [3]f64,
};

pub const Section = struct {
    id: []const u8,
    from: []const u8,
    to: []const u8,
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

    fn of(state: solve.SampleState) Sample {
        return .{
            .time = state.time_s,
            .distance = state.distance_m,
            .latitude = state.latitude_deg,
            .longitude = state.longitude_deg,
            .altitude = state.altitude_m,
            .speed = state.speed_mps,
            .horizontalSpeed = state.horizontal_speed_mps,
            .forwardSpeed = state.forward_speed_mps,
            .up = state.up_mps,
            .acceleration = state.acceleration_mps2,
            .forwardAcceleration = state.forward_acceleration_mps2,
            .jerk = state.jerk_mps3,
            .forwardJerk = state.forward_jerk_mps3,
            .course = state.course_deg,
            .turnRate = state.turn_rate_degps,
            .lateralAcceleration = state.lateral_acceleration_mps2,
        };
    }
};

pub const Rule = struct {
    id: []const u8,
    kind: model.RuleKind,
    violation: f64,
    residual: f64,
    active: bool,
};

pub const Inspection = struct {
    distance: f64,
    duration: f64,
    solve: Report,
    events: []const Event,
    sections: []const Section,
    samples: []const Sample,
    rules: []const Rule,
};

pub const Error = error{ OutOfMemory, InvalidSampleCount };

pub const Position = struct {
    latitude: f64,
    longitude: f64,

    fn of(ecef: model.Vector) Position {
        const lla = core.coord.ecefToLla(ecef);
        return .{ .latitude = lla.latDeg(), .longitude = lla.lonDeg() };
    }
};

pub const GeometryPath = struct { id: []const u8, positions: []const Position };
pub const GeometryRegion = struct { id: []const u8, positions: []const Position, radiusPoint: ?Position };
pub const GeometryInspection = struct { curves: []const GeometryPath, regions: []const GeometryRegion };

pub fn geometry(arena: std.mem.Allocator, value: model.Geometry, subdivisions: usize) Error!GeometryInspection {
    if (subdivisions == 0) return error.InvalidSampleCount;
    const curves = try arena.alloc(GeometryPath, value.curves.len);
    for (value.curves, curves, 0..) |curve, *out, index| {
        const segments = switch (curve.kind) {
            .bezier => (curve.points.len - 1) / 3,
            .polyline => curve.points.len - 1,
        };
        const steps = std.math.mul(usize, segments, subdivisions) catch return error.InvalidSampleCount;
        const count = std.math.add(usize, steps, 1) catch return error.InvalidSampleCount;
        const positions = try arena.alloc(Position, count);
        for (positions, 0..) |*position, i| {
            const fraction = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            position.* = .of(plan.geometry.curve(value, index, fraction).position);
        }
        out.* = .{ .id = curve.id, .positions = positions };
    }
    const regions = try arena.alloc(GeometryRegion, value.regions.len);
    for (value.regions, regions) |region, *out| {
        out.* = switch (region.shape) {
            .circle => |circle| blk: {
                const count = std.math.mul(usize, subdivisions, 2) catch return error.InvalidSampleCount;
                const positions = try arena.alloc(Position, count);
                const plane = plan.geometry.Plane.at(value.points[circle.center].ecef);
                for (positions, 0..) |*position, i| {
                    const angle = core.constants.two_pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count));
                    position.* = .of(plane.unproject(.{ circle.radius * @sin(angle), circle.radius * @cos(angle) }));
                }
                break :blk .{ .id = region.id, .positions = positions, .radiusPoint = .of(plane.unproject(.{ circle.radius, 0 })) };
            },
            .polygon => |indices| blk: {
                const count = std.math.mul(usize, indices.len, subdivisions) catch return error.InvalidSampleCount;
                const positions = try arena.alloc(Position, count);
                const plane = plan.geometry.polygonPlane(value.points, indices);
                for (indices, 0..) |point, side| {
                    const from = plane.project(value.points[point].ecef);
                    const to = plane.project(value.points[indices[(side + 1) % indices.len]].ecef);
                    for (0..subdivisions) |i| {
                        const fraction = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(subdivisions));
                        positions[side * subdivisions + i] = .of(plane.unproject(.{
                            from[0] + (to[0] - from[0]) * fraction,
                            from[1] + (to[1] - from[1]) * fraction,
                        }));
                    }
                }
                break :blk .{ .id = region.id, .positions = positions, .radiusPoint = null };
            },
        };
    }
    return .{ .curves = curves, .regions = regions };
}

const Request = struct { time_s: f64, before: bool = false };

pub fn of(arena: std.mem.Allocator, built: source.Result, sample_count: usize) Error!Inspection {
    if (sample_count < 2) return error.InvalidSampleCount;
    const duration = built.trajectory.duration();
    const events = try arena.alloc(Event, built.plan.events.len);
    const sections = try arena.alloc(Section, built.plan.sections.len);
    const rules = try arena.alloc(Rule, built.rule_reports.len);
    var requests: std.ArrayList(Request) = .empty;
    var events_cursor = built.path.cursor();
    for (built.plan.events, built.path.event_times, 0..) |event, time, i| {
        const state = events_cursor.sample(time, false);
        events[i] = .{
            .id = event.id,
            .index = i,
            .time = time,
            .latitude = state.latitude_deg,
            .longitude = state.longitude_deg,
            .altitude = state.altitude_m,
            .speed = state.speed_mps,
            .course = state.course_deg,
            .velocityEcef = state.velocity_ecef,
            .accelerationEcef = state.acceleration_ecef,
        };
        try requests.appendSlice(arena, &.{ .{ .time_s = time, .before = true }, .{ .time_s = time } });
    }
    for (built.plan.sections, sections, 0..) |section, *result, i| result.* = .{
        .id = section.id,
        .from = built.plan.events[i].id,
        .to = built.plan.events[i + 1].id,
        .start = built.path.event_times[i],
        .end = built.path.event_times[i + 1],
    };
    for (built.rule_reports, rules) |rule, *result| result.* = .{
        .id = rule.id,
        .kind = rule.kind,
        .violation = rule.violation,
        .residual = rule.residual,
        .active = rule.active,
    };
    for (built.trajectory.knots) |knot| try requests.appendSlice(arena, &.{ .{ .time_s = knot.t, .before = true }, .{ .time_s = knot.t } });
    const intervals: f64 = @floatFromInt(sample_count - 1);
    for (0..sample_count) |i| try requests.append(arena, .{ .time_s = duration * @as(f64, @floatFromInt(i)) / intervals });
    std.mem.sort(Request, requests.items, {}, requestBefore);
    var samples: std.ArrayList(Sample) = .empty;
    var cursor = built.path.cursor();
    for (requests.items, 0..) |request, i| {
        if (i > 0 and std.meta.eql(requests.items[i - 1], request)) continue;
        const value = Sample.of(cursor.sample(request.time_s, request.before));
        if (samples.items.len == 0 or !std.meta.eql(samples.items[samples.items.len - 1], value)) try samples.append(arena, value);
    }
    return .{
        .distance = built.path.distances[built.path.distances.len - 1],
        .duration = duration,
        .solve = .{
            .status = @tagName(built.report.status),
            .feasible = built.report.feasible,
            .verified = built.report.verified,
            .settled = built.report.settled,
            .iterations = built.report.iterations,
            .work = built.report.work,
            .tier = @tagName(built.report.tier),
            .cells = built.report.cells,
            .passes = built.report.passes,
            .overruns = built.report.overruns,
            .objective = built.report.objective,
            .maxViolation = built.report.max_violation,
            .stationarity = built.report.stationarity,
        },
        .events = events,
        .sections = sections,
        .samples = samples.items,
        .rules = rules,
    };
}

fn requestBefore(_: void, left: Request, right: Request) bool {
    if (left.time_s != right.time_s) return left.time_s < right.time_s;
    return left.before and !right.before;
}
