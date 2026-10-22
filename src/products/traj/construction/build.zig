//! Construct each segment forward, count its samples, then allocate and write the final path once.
const std = @import("std");
const diagnostics = @import("base/diagnostics");
const trajectory = @import("domain/trajectory/trajectory");
const model = @import("products/traj/input/model");
const track = @import("products/traj/motion/geometry/track");
const segments = @import("products/traj/construction/segments");
const sampling = @import("products/traj/construction/sampling");

const Diagnostics = diagnostics.Diagnostics;
const Knot = trajectory.Knot;

pub const Error = diagnostics.InputError;

pub const SegmentInfo = struct {
    first_knot: usize,
    ground_length_m: f64,
    end_ground_speed_mps: f64,
};

pub const Path = struct {
    trajectory: trajectory.Trajectory,
    segments: []const SegmentInfo,

    pub fn endKnot(self: *const Path, segment: usize) Knot {
        const knots = self.trajectory.knots;
        return knots[if (segment + 1 < self.segments.len) self.segments[segment + 1].first_knot else knots.len - 1];
    }
};

pub const BuildOutput = struct { path: Path, outside: ?segments.Outside };

const SampledSegment = union(enum) {
    stay: Knot,
    through: sampling.SampledThrough,
    run: sampling.SampledRun,
};

/// The result arena owns the path; scratch owns only construction and sampling work.
pub fn build(arena: std.mem.Allocator, scratch: std.mem.Allocator, plan: *const model.Plan, diags: *Diagnostics) Error!BuildOutput {
    var outside: ?segments.Outside = null;
    var builder = try segments.Builder.init(scratch, plan, diags, &outside);
    var sampler: sampling.Sampler = .{ .scratch = scratch, .diags = diags, .outside = &outside };
    const sampled = try scratch.alloc(SampledSegment, plan.segments.len);
    const info = try arena.alloc(SegmentInfo, plan.segments.len);
    var state = segments.startState(plan);
    var last: ?Knot = if (state.vel != null and state.acc != null) segments.knotOf(state) else null;
    var first = last;
    var i: usize = 0;
    while (i < plan.segments.len) : (i += 1) {
        const first_knot = sampler.count - 1;
        switch (plan.segments[i].motion) {
            .stay => |span| {
                const end = try builder.spanEnd(i, span, state.time);
                try sampler.take(i, 1);
                const knot = segments.atRest(end, state.pos);
                sampled[i] = .{ .stay = knot };
                info[i] = .{ .first_knot = first_knot, .ground_length_m = 0, .end_ground_speed_mps = 0 };
                last = knot;
                state.time = end;
                if (state.vertical) |v| state.vertical = .{ v[0], 0, 0 };
            },
            .through => |through| {
                try builder.after(i, "through.places[0].time", through.visits[0].time, state.time);
                const end = through.visits[through.visits.len - 1];
                var next: ?segments.ReadyRun = null;
                if (through.end == .free and i + 1 < plan.segments.len and segments.isRun(plan.segments[i + 1])) {
                    next = try segments.prepare(&builder, i + 1, segments.placeState(plan, end.time, end.place));
                }
                const held = if (next) |*ready| ready.prepared.motion.knot(ready.prepared.motion.start, ready.prepared.spans[0].side) else null;
                const solved = try segments.solveThrough(&builder, i, state, through.visits, through.end == .rest, held);
                if (first == null) first = solved.knot(0);
                const cuts = try scratch.alloc([]const f64, solved.times.len - 1);
                for (cuts, 0..) |*cut, piece| {
                    cut.* = try sampling.cut(&sampler, i, .{ .through = .{ .solved = &solved, .piece = piece } });
                    try sampler.take(i, cut.len);
                }
                sampled[i] = .{ .through = .{ .solved = solved, .cuts = cuts } };
                last = solved.knot(solved.times.len - 1);
                info[i] = .{ .first_knot = first_knot, .ground_length_m = segments.groundLength(&solved), .end_ground_speed_mps = track.footSpeed(last.?.pos, last.?.vel, last.?.acc)[0] };
                const place = &plan.places[end.place];
                state = .{
                    .time = end.time,
                    .pos = place.ecef,
                    .vel = last.?.vel,
                    .acc = last.?.acc,
                    .height = place.height,
                    .place = end.place,
                    .foot = segments.footOf(place.ecef),
                    .tangent = null,
                    .speed = if (through.end == .rest) 0 else null,
                    .vertical = if (through.end == .rest) .{ place.altitude, 0, 0 } else null,
                };
                const ready = next orelse continue;
                i += 1;
                const next_first = sampler.count - 1;
                const run = try sampling.sampleRun(&sampler, i, &ready, last);
                sampled[i] = .{ .run = run };
                info[i] = .{ .first_knot = next_first, .ground_length_m = run.motion.timing.length(), .end_ground_speed_mps = run.motion.timing.v1 };
                last = run.spans[run.spans.len - 1].piece.last;
                state = ready.end;
            },
            .straight, .turn, .along => {
                const ready = try segments.prepare(&builder, i, state);
                const run = try sampling.sampleRun(&sampler, i, &ready, last);
                sampled[i] = .{ .run = run };
                info[i] = .{ .first_knot = first_knot, .ground_length_m = run.motion.timing.length(), .end_ground_speed_mps = run.motion.timing.v1 };
                last = run.spans[run.spans.len - 1].piece.last;
                if (first == null) first = run.spans[0].piece.first;
                state = ready.end;
            },
        }
    }
    const knots = try arena.alloc(Knot, sampler.count);
    knots[0] = first.?;
    var written: usize = 1;
    for (sampled) |*segment| switch (segment.*) {
        .stay => |knot| {
            knots[written] = knot;
            written += 1;
        },
        .through => |*through| for (through.cuts, 0..) |cuts, piece| {
            const source: sampling.Source = .{ .through = .{ .solved = &through.solved, .piece = piece } };
            for (cuts) |u| {
                knots[written] = source.point(u);
                written += 1;
            }
        },
        .run => |*run| for (run.spans) |*span| {
            if (!std.meta.eql(span.piece.first, knots[written - 1])) {
                knots[written] = span.piece.first;
                written += 1;
            }
            const source: sampling.Source = .{ .run = .{ .motion = &run.motion, .piece = &span.piece } };
            for (span.cuts) |u| {
                knots[written] = source.point(u);
                written += 1;
            }
        },
    };
    std.debug.assert(written == knots.len);
    return .{ .path = .{ .trajectory = .{ .name = plan.name, .knots = knots }, .segments = info }, .outside = outside };
}
