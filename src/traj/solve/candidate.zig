const std = @import("std");
const shared = @import("shared");
const model = @import("../plan.zig").model;
const kernel = @import("kernel.zig");
const Scalar = kernel.Scalar;
const sample_quantities: []const model.Quantity = &.{ .altitude, .speed3d, .horizontal_speed, .forward_speed, .climb_rate, .acceleration3d, .forward_acceleration, .jerk3d, .forward_jerk, .course, .turn_rate, .lateral_acceleration };
const sample_requirements = [_]kernel.Requirements{ .init(sample_quantities, false), .init(sample_quantities, true) };

pub const SampleState = struct {
    time_s: f64,
    distance_m: f64,
    latitude_deg: f64,
    longitude_deg: f64,
    altitude_m: f64,
    speed_mps: f64,
    horizontal_speed_mps: f64,
    forward_speed_mps: f64,
    up_mps: f64,
    acceleration_mps2: f64,
    forward_acceleration_mps2: f64,
    jerk_mps3: f64,
    forward_jerk_mps3: f64,
    course_deg: f64,
    turn_rate_degps: f64,
    lateral_acceleration_mps2: f64,
    velocity_ecef: [3]f64,
    acceleration_ecef: [3]f64,
};

pub const Cell = struct { section: usize, left: usize, right: usize, start: f64, end: f64 };
pub const Section = struct { first_cell: usize, end_cell: usize };
pub const Location = struct { index: usize, u: f64 };
pub const Progress = struct { time: f64, value: f64 };
pub const CurveProgress = struct { rule: usize, samples: []const Progress };
pub const Candidate = struct {
    path: Path,
    curves: []const CurveProgress = &.{},

    pub fn progress(self: *const Candidate, rule: usize, time: f64) f64 {
        for (self.curves) |curve| {
            if (curve.rule != rule) continue;
            const samples = curve.samples;
            if (samples.len == 0) return std.math.nan(f64);
            var low: usize = 0;
            var high = samples.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (samples[middle].time < time) low = middle + 1 else high = middle;
            }
            if (low == 0) return samples[0].value;
            if (low == samples.len) return samples[samples.len - 1].value;
            if (samples[low].time == time) return samples[low].value;
            const left = samples[low - 1];
            const right = samples[low];
            return left.value + (right.value - left.value) * (time - left.time) / (right.time - left.time);
        }
        return std.math.nan(f64);
    }
};

pub const Path = struct {
    name: []const u8,
    datum: model.Altitude,
    oriented: bool,
    nodes: []const Scalar.Jet,
    cells: []const Cell,
    event_times: []const f64,
    durations: []const f64,
    sections: []const Section,
    distances: []const f64,
    evaluators: []const Scalar.Cell,

    pub fn init(arena: std.mem.Allocator, name: []const u8, datum: model.Altitude, oriented: bool, nodes: []const Scalar.Jet, cells: []const Cell, durations: []const f64) std.mem.Allocator.Error!Path {
        const event_times = try arena.alloc(f64, durations.len + 1);
        event_times[0] = 0;
        for (durations, 0..) |span, i| event_times[i + 1] = event_times[i] + span;
        const sections = try arena.alloc(Section, durations.len);
        var cell_cursor: usize = 0;
        for (sections, 0..) |*section, index| {
            const first = cell_cursor;
            while (cell_cursor < cells.len and cells[cell_cursor].section == index) cell_cursor += 1;
            section.* = .{ .first_cell = first, .end_cell = cell_cursor };
        }
        const evaluators = try arena.alloc(Scalar.Cell, cells.len);
        for (evaluators, cells) |*evaluator, cell| evaluator.* = Scalar.Cell.init(nodes[cell.left], nodes[cell.right], durations[cell.section] * (cell.end - cell.start));
        const distances = try arena.alloc(f64, cells.len + 1);
        const result: Path = .{ .name = name, .datum = datum, .oriented = oriented, .nodes = nodes, .cells = cells, .event_times = event_times, .durations = durations, .sections = sections, .distances = distances, .evaluators = evaluators };
        distances[0] = 0;
        for (cells, 0..) |_, cell| distances[cell + 1] = distances[cell] + result.distance(cell, 1);
        return result;
    }

    pub fn duration(self: *const Path, section: usize) f64 {
        return self.durations[section];
    }

    pub fn totalDuration(self: *const Path) f64 {
        return self.event_times[self.event_times.len - 1];
    }

    pub fn event(self: *const Path, index: usize, side: model.Side) Scalar.Jet {
        const location = self.eventLocation(.{ .index = index, .side = side });
        const cell = self.cells[location.index];
        return self.nodes[if (location.u == 0) cell.left else cell.right];
    }

    pub fn eventLocation(self: *const Path, reference: model.EventRef) Location {
        if (reference.index == 0 or (reference.side == .out and reference.index < self.sections.len)) return .{ .index = self.sections[reference.index].first_cell, .u = 0 };
        return .{ .index = self.sections[reference.index - 1].end_cell - 1, .u = 1 };
    }

    pub fn locate(self: *const Path, time: f64, before: bool) Location {
        var low: usize = 0;
        var high = self.cells.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const end = self.timeAt(middle, 1);
            if (time < end or (before and time == end)) high = middle else low = middle + 1;
        }
        const index = @min(low, self.cells.len - 1);
        const start = self.timeAt(index, 0);
        return .{ .index = index, .u = std.math.clamp((time - start) / self.cellDuration(index), 0, 1) };
    }

    pub fn timeAt(self: *const Path, cell_index: usize, u: f64) f64 {
        const cell = self.cells[cell_index];
        return self.event_times[cell.section] + self.duration(cell.section) * (cell.start + u * (cell.end - cell.start));
    }

    pub fn cellDuration(self: *const Path, index: usize) f64 {
        const cell = self.cells[index];
        return self.duration(cell.section) * (cell.end - cell.start);
    }

    pub fn state(self: *const Path, index: usize, u: f64) Scalar.State {
        return self.evaluators[index].at(u);
    }

    pub fn sampleSection(self: *const Path, section: usize, fraction: f64) Scalar.Jet {
        const span = self.sections[section];
        var low = span.first_cell;
        var high = span.end_cell;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (fraction <= self.cells[middle].end) high = middle else low = middle + 1;
        }
        const index = @min(low, span.end_cell - 1);
        const cell = self.cells[index];
        const s = self.state(index, (fraction - cell.start) / (cell.end - cell.start));
        return .{ .position = s.position, .velocity = s.velocity, .acceleration = s.acceleration, .course = s.course, .turn_rate = s.turn_rate };
    }

    pub fn scopeDuration(self: *const Path, scope: model.Scope) f64 {
        return switch (scope) {
            .event, .time => 0,
            .section => |section| self.duration(section),
            .between => |ends| self.event_times[ends[1]] - self.event_times[ends[0]],
            .time_range => |range| range[1] - range[0],
            .all => self.totalDuration(),
        };
    }

    pub fn distance(self: *const Path, index: usize, fraction: f64) f64 {
        const nodes = [_]f64{ 0, -0.5384693101056831, 0.5384693101056831, -0.9061798459386640, 0.9061798459386640 };
        const weights = [_]f64{ 0.5688888888888889, 0.4786286704993665, 0.4786286704993665, 0.2369268850561891, 0.2369268850561891 };
        var sum: f64 = 0;
        for (nodes, weights) |node, weight| {
            const velocity = self.state(index, (node + 1) * fraction / 2).velocity;
            sum += weight * @sqrt(Scalar.normSquared(velocity));
        }
        return sum * fraction / 2 * self.cellDuration(index);
    }

    pub fn sample(self: *const Path, time: f64, before: bool) SampleState {
        return self.sampleAt(time, self.locate(time, before));
    }

    fn sampleAt(self: *const Path, time: f64, location: Location) SampleState {
        var point = Scalar.Point.init(self.state(location.index, location.u), self.datum, !self.oriented);
        point.prepareRequirements(sample_requirements[@intFromBool(!self.oriented)]);
        const sampled = point.alignedState();
        const lla = shared.core.coord.ecefToLla(.fromArray(sampled.position));
        return .{
            .time_s = time,
            .distance_m = self.distances[location.index] + self.distance(location.index, location.u),
            .latitude_deg = lla.latDeg(),
            .longitude_deg = lla.lonDeg(),
            .altitude_m = point.quantity(.altitude)[0],
            .speed_mps = point.quantity(.speed3d)[0],
            .horizontal_speed_mps = point.quantity(.horizontal_speed)[0],
            .forward_speed_mps = point.quantity(.forward_speed)[0],
            .up_mps = point.quantity(.climb_rate)[0],
            .acceleration_mps2 = point.quantity(.acceleration3d)[0],
            .forward_acceleration_mps2 = point.quantity(.forward_acceleration)[0],
            .jerk_mps3 = point.quantity(.jerk3d)[0],
            .forward_jerk_mps3 = point.quantity(.forward_jerk)[0],
            .course_deg = point.quantity(.course)[0],
            .turn_rate_degps = point.quantity(.turn_rate)[0],
            .lateral_acceleration_mps2 = point.quantity(.lateral_acceleration)[0],
            .velocity_ecef = sampled.velocity,
            .acceleration_ecef = sampled.acceleration,
        };
    }

    pub fn cursor(self: *const Path) Cursor {
        return .{ .path = self };
    }

    pub fn trajectory(self: *const Path, arena: std.mem.Allocator) std.mem.Allocator.Error!shared.trajectory.Trajectory {
        var knots: std.ArrayList(shared.trajectory.Knot) = .empty;
        for (self.cells, 0..) |cell, i| {
            const left = knot(self.nodes[cell.left], self.timeAt(i, 0));
            if (knots.items.len == 0 or !std.meta.eql(knots.items[knots.items.len - 1], left)) try knots.append(arena, left);
            try knots.append(arena, knot(self.nodes[cell.right], self.timeAt(i, 1)));
        }
        return .{ .name = self.name, .knots = knots.items };
    }

    pub fn clone(self: *const Path, arena: std.mem.Allocator) std.mem.Allocator.Error!Path {
        return .{
            .name = try arena.dupe(u8, self.name),
            .datum = self.datum,
            .oriented = self.oriented,
            .nodes = try arena.dupe(Scalar.Jet, self.nodes),
            .cells = try arena.dupe(Cell, self.cells),
            .event_times = try arena.dupe(f64, self.event_times),
            .durations = try arena.dupe(f64, self.durations),
            .sections = try arena.dupe(Section, self.sections),
            .distances = try arena.dupe(f64, self.distances),
            .evaluators = try arena.dupe(Scalar.Cell, self.evaluators),
        };
    }
};

fn knot(jet: Scalar.Jet, time: f64) shared.trajectory.Knot {
    return .{ .t = time, .pos = .fromArray(jet.position), .vel = .fromArray(jet.velocity), .acc = .fromArray(jet.acceleration) };
}

pub const Cursor = struct {
    path: *const Path,
    index: usize = 0,

    pub fn sample(self: *Cursor, time: f64, before: bool) SampleState {
        const start = self.path.timeAt(self.index, 0);
        if (time < start or (before and time == start and self.index != 0)) {
            const location = self.path.locate(time, before);
            self.index = location.index;
            return self.path.sampleAt(time, location);
        }
        while (self.index + 1 < self.path.cells.len) {
            const end = self.path.timeAt(self.index, 1);
            if (time < end or (before and time == end)) break;
            self.index += 1;
        }
        const u = std.math.clamp((time - self.path.timeAt(self.index, 0)) / self.path.cellDuration(self.index), 0, 1);
        return self.path.sampleAt(time, .{ .index = self.index, .u = u });
    }
};
