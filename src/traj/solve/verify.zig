const std = @import("std");
const core = @import("shared").core;
const trajectory = @import("shared").trajectory;
const model = @import("../plan.zig").model;
const rules = @import("rules.zig");
const candidate_module = @import("candidate.zig");
const Scalar = @import("kernel.zig").Scalar;
const polynomials = @import("verify/polynomial.zig");
const Polynomial = polynomials.Polynomial;
const bounds = polynomials.bounds;
const bound_accuracy = polynomials.bound_accuracy;

pub const tolerance: f64 = 1e-5;

pub const RuleReport = struct {
    id: []const u8,
    kind: model.RuleKind,
    violation: f64,
    residual: f64,
    active: bool,
};

pub const Result = struct {
    feasible: bool,
    verified: bool,
    max_violation: f64,
    rules: []const RuleReport,
    refine_sections: []const bool,
};

pub fn check(arena: std.mem.Allocator, prepared: *const rules.Prepared, candidate: *const candidate_module.Candidate) !Result {
    const reports = try arena.alloc(RuleReport, prepared.plan.rules.len);
    for (reports, prepared.plan.rules) |*report, rule| report.* = .{ .id = rule.id, .kind = rule.kind(), .violation = 0, .residual = 0, .active = false };
    const refine = try arena.alloc(bool, prepared.plan.sections.len);
    @memset(refine, false);
    const seen = try arena.alloc(bool, reports.len);
    @memset(seen, false);
    const cells = try arena.alloc(polynomials.CellPolynomials, candidate.path.cells.len);
    for (cells, 0..) |*cell, index| cell.* = .init(&candidate.path, index);
    var result: Result = .{ .feasible = true, .verified = true, .max_violation = 0, .rules = reports, .refine_sections = refine };
    var context: Context = .{ .prepared = prepared, .candidate = candidate, .path = &candidate.path, .cells = cells, .result = &result, .reports = reports, .refine = refine, .seen = seen };
    context.domainBounds();
    context.continuity();
    context.curveProgress();
    for (prepared.checks) |term| {
        switch (term.scope) {
            .event => |event| context.point(term, candidate.path.eventLocation(event)),
            .time => |time| context.point(term, timeLocation(&candidate.path, time)),
            else => {
                for (candidate.path.cells, 0..) |_, index| {
                    const interval = scopedInterval(&candidate.path, term.scope, index) orelse continue;
                    context.interval(term, index, interval[0], interval[1]);
                }
            },
        }
    }
    context.impulses();
    for (reports) |*report| {
        if (!std.math.isFinite(report.violation)) report.violation = 1e300;
        if (!std.math.isFinite(report.residual)) report.residual = if (report.residual < 0) -1e300 else 1e300;
    }
    return result;
}

const Sampler = struct {
    candidate: *const candidate_module.Candidate,
    location: candidate_module.Location,
    cached: ?Scalar.Point = null,
    requested_time: ?f64 = null,

    pub fn point(self: *Sampler) *Scalar.Point {
        if (self.cached == null) {
            const path = &self.candidate.path;
            self.cached = Scalar.Point.init(path.state(self.location.index, self.location.u), path.datum, !path.oriented);
        }
        return &self.cached.?;
    }

    pub fn quantity(self: *Sampler, q: model.Quantity, scope: model.Scope) [3]f64 {
        return switch (q) {
            .time => Scalar.scalar(self.requested_time orelse self.candidate.path.timeAt(self.location.index, self.location.u)),
            .duration => Scalar.scalar(self.candidate.path.scopeDuration(scope)),
            else => self.point().quantity(q),
        };
    }

    pub fn eventTime(self: *const Sampler, event: usize) f64 {
        return self.candidate.path.event_times[event];
    }

    pub fn eventQuantity(self: *const Sampler, event: model.EventRef, q: model.Quantity) [3]f64 {
        var sampler: Sampler = .{ .candidate = self.candidate, .location = self.candidate.path.eventLocation(event) };
        return sampler.quantity(q, .{ .event = event });
    }

    pub fn progress(self: *const Sampler, rule: usize) f64 {
        return self.candidate.progress(rule, self.candidate.path.timeAt(self.location.index, self.location.u));
    }
};

const Context = struct {
    prepared: *const rules.Prepared,
    candidate: *const candidate_module.Candidate,
    path: *const candidate_module.Path,
    cells: []const polynomials.CellPolynomials,
    result: *Result,
    reports: []RuleReport,
    refine: []bool,
    seen: []bool,

    fn record(self: *Context, term: rules.Check, residual: f64, cell: usize) void {
        const index = term.ruleIndex();
        const hard = if (index) |i| self.prepared.plan.rules[i].kind() == .hard else true;
        const finite = std.math.isFinite(residual);
        const violation = if (!finite) std.math.inf(f64) else if (!hard) 0 else if (term.equality) @abs(residual) else @max(0, -residual);
        if (index) |i| {
            const report = &self.reports[i];
            report.violation = @max(report.violation, violation);
            const worse = if (hard and !term.equality) residual < report.residual else @abs(residual) > @abs(report.residual);
            if (!self.seen[i] or !finite or worse) report.residual = residual;
            self.seen[i] = true;
            report.active = report.active or (hard and (term.equality or @abs(residual) <= tolerance));
        }
        self.result.max_violation = @max(self.result.max_violation, violation);
        if (!finite) self.result.verified = false;
        if (violation > tolerance) {
            self.result.feasible = false;
            self.refine[self.path.cells[cell].section] = true;
        }
    }

    fn unresolved(self: *Context, cell: usize) void {
        self.result.verified = false;
        self.refine[self.path.cells[cell].section] = true;
    }

    fn point(self: *Context, term: rules.Check, location: candidate_module.Location) void {
        self.record(term, self.residualAt(term, location), location.index);
    }

    fn residualAt(self: *const Context, term: rules.Check, location: candidate_module.Location) f64 {
        var sampler: Sampler = .{ .candidate = self.candidate, .location = location, .requested_time = if (term.scope == .time) term.scope.time else null };
        return rules.residual(Scalar, self.prepared, term, &sampler, .verification);
    }

    fn interval(self: *Context, term: rules.Check, cell: usize, start: f64, end: f64) void {
        if (self.polynomial(term, cell)) |p| {
            const range = bounds(p, start, end);
            const worst = if (term.equality or !self.isHard(term)) (if (@abs(range.lower) > @abs(range.upper)) range.lower else range.upper) else range.lower;
            self.record(term, worst, cell);
            if (!range.resolved and self.isHard(term)) self.unresolved(cell);
            return;
        }

        if (term.operation == .quantity) {
            const operation = term.operation.quantity;
            const rule = self.prepared.plan.rules[operation.rule];
            if (rule.definition.quantity.quantity == .turn_radius) {
                const jets = self.cells[cell];
                const rate = jets.course.derivative().scaled(1 / jets.duration);
                if (rule.kind() == .hard and operation.comparison == .eq) {
                    self.radiusLimits(term, cell, start, end, rate, jets.duration);
                } else {
                    const rates = bounds(rate, start, end);
                    if (rates.lower <= 0 and rates.upper >= 0) self.unresolved(cell);
                }
            }
        }

        const required = self.subdivisions(cell, start, end);
        if (required > 1024) self.unresolved(cell);
        const count = @min(required, 1024);
        var left = self.at(term, cell, start);
        for (0..count) |i| {
            const a = start + (end - start) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count));
            const b = start + (end - start) * @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(count));
            const right = self.at(term, cell, b);
            self.adaptive(term, cell, a, b, left, right, count, 0);
            left = right;
        }
    }

    fn at(self: *Context, term: rules.Check, cell: usize, u: f64) f64 {
        const value = self.residualAt(term, .{ .index = cell, .u = u });
        self.record(term, value, cell);
        return value;
    }

    fn radiusLimits(self: *Context, term: rules.Check, cell: usize, start: f64, end: f64, rate: Polynomial, duration: f64) void {
        const a = rate.coefficients[2];
        const b = rate.coefficients[1];
        const c = rate.coefficients[0];
        const enclosure = bounds(rate, start, end);
        const possible_zero = enclosure.lower <= 0 and enclosure.upper >= 0;
        if (a == 0) {
            if (b != 0) {
                const root = -c / b;
                self.radiusLimit(term, cell, start, end, root, false, rate, duration);
                if (possible_zero and (root < start or root > end)) self.unresolved(cell);
            }
            return;
        }
        const scale = @max(@abs(a), @max(@abs(b), @abs(c)));
        const an = a / scale;
        const bn = b / scale;
        const cn = c / scale;
        const discriminant = bn * bn - 4 * an * cn;
        if (!std.math.isFinite(discriminant)) {
            self.unresolved(cell);
            return;
        }
        if (discriminant < 0) {
            if (possible_zero) self.unresolved(cell);
            return;
        }
        if (discriminant == 0) {
            const root = -bn / (2 * an);
            self.radiusLimit(term, cell, start, end, root, true, rate, duration);
            if (possible_zero and (root < start or root > end)) self.unresolved(cell);
            return;
        }
        const q = -0.5 * (bn + std.math.copysign(@sqrt(discriminant), bn));
        const first = q / an;
        const second = cn / q;
        self.radiusLimit(term, cell, start, end, first, false, rate, duration);
        self.radiusLimit(term, cell, start, end, second, false, rate, duration);
        if (possible_zero and (first < start or first > end) and (second < start or second > end)) self.unresolved(cell);
    }

    fn radiusLimit(self: *Context, term: rules.Check, cell: usize, start: f64, end: f64, root: f64, double: bool, rate: Polynomial, duration: f64) void {
        if (!std.math.isFinite(root)) {
            self.unresolved(cell);
            return;
        }
        if (root < start or root > end) return;
        const state = self.path.state(cell, root);
        var point_at_root = Scalar.Point.init(state, self.path.datum, !self.path.oriented);
        point_at_root.prepare(&.{ .forward_speed, .forward_acceleration, .forward_jerk });
        const forward = point_at_root.quantity(.forward_speed)[0];
        const acceleration = point_at_root.quantity(.forward_acceleration)[0];
        if (forward != 0 or (double and acceleration != 0)) {
            self.unresolved(cell);
            return;
        }
        const numerator = if (double) point_at_root.quantity(.forward_jerk)[0] else acceleration;
        const denominator = if (double) 2 * rate.coefficients[2] / (duration * duration) else (2 * rate.coefficients[2] * root + rate.coefficients[1]) / duration;
        const rule = self.prepared.plan.rules[term.operation.quantity.rule];
        const target = self.rightHand(rule.definition.quantity.comparison.eq, 0);
        self.record(term, (numerator / denominator - target) / rule.scale, cell);
    }

    fn adaptive(self: *Context, term: rules.Check, cell: usize, a: f64, b: f64, left: f64, right: f64, base: usize, depth: usize) void {
        const middle = self.at(term, cell, (a + b) * 0.5);
        const quarter = self.at(term, cell, a * 0.75 + b * 0.25);
        const three_quarters = self.at(term, cell, a * 0.25 + b * 0.75);
        if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(middle) or !std.math.isFinite(quarter) or !std.math.isFinite(three_quarters)) {
            self.unresolved(cell);
            return;
        }
        if (!self.isHard(term)) return;
        const curvature = @max(@abs(middle - 0.5 * (left + right)), @max(@abs(quarter - 0.5 * (left + middle)), @abs(three_quarters - 0.5 * (middle + right))));
        const magnitude = @max(@abs(left), @max(@abs(middle), @abs(right)));
        const accuracy = bound_accuracy * @max(1, magnitude);
        var safe = curvature <= accuracy;
        const minimum = @min(@min(left, right), @min(middle, @min(quarter, three_quarters)));
        const maximum = @max(@max(left, right), @max(middle, @max(quarter, three_quarters)));
        if (term.equality) {
            safe = safe or @max(@abs(minimum), @abs(maximum)) + 4 * curvature <= tolerance;
        } else {
            safe = safe or minimum - 4 * curvature >= -tolerance;
        }
        if (safe) return;
        if (base * (@as(usize, 1) << @intCast(depth)) >= 1024) {
            self.unresolved(cell);
            return;
        }
        const midpoint = (a + b) * 0.5;
        self.adaptive(term, cell, a, midpoint, left, middle, base, depth + 1);
        self.adaptive(term, cell, midpoint, b, middle, right, base, depth + 1);
    }

    fn subdivisions(self: *const Context, cell: usize, start: f64, end: f64) usize {
        const jets = self.cells[cell];
        const rates = bounds(jets.course.derivative().scaled(1 / jets.duration), start, end);
        const turn = @max(@abs(rates.lower), @abs(rates.upper)) * jets.duration * (end - start);
        if (!std.math.isFinite(turn)) return 1025;
        return @max(16, @as(usize, @intFromFloat(@min(1025, @ceil(turn / (std.math.pi / 16.0))))));
    }

    fn isHard(self: *const Context, term: rules.Check) bool {
        return if (term.ruleIndex()) |index| self.prepared.plan.rules[index].kind() == .hard else true;
    }

    fn domainBounds(self: *Context) void {
        const scale = core.constants.wgs_axis_a;
        const minimum = (trajectory.min_radius_m / scale) * (trajectory.min_radius_m / scale);
        const maximum = (trajectory.max_radius_m / scale) * (trajectory.max_radius_m / scale);
        for (self.path.cells, 0..) |cell, index| {
            const jets = self.cells[index];
            var squared = Polynomial.constant(0);
            for (jets.position) |p| squared = squared.add(p.scaled(1 / scale).square());
            const range = bounds(squared, 0, 1);
            if (!range.resolved) self.unresolved(index);
            const violation = @max(0, @max(minimum - range.lower, range.upper - maximum));
            self.result.max_violation = @max(self.result.max_violation, violation);
            if (violation > 1e-10) {
                self.result.feasible = false;
                self.refine[cell.section] = true;
            }
            if (!std.math.isFinite(violation)) self.result.verified = false;
        }
    }

    fn continuity(self: *Context) void {
        for (self.path.cells[1..], 1..) |cell, index| {
            const previous = self.path.cells[index - 1];
            const required = if (cell.section == previous.section) model.Continuity.c2 else self.prepared.plan.events[cell.section].continuity;
            const before = self.path.state(index - 1, 1);
            const after = self.path.state(index, 0);
            var violation = difference(before.position, after.position, 100);
            if (required != .c0) violation = @max(violation, difference(before.velocity, after.velocity, 10));
            if (required == .c2) violation = @max(violation, difference(before.acceleration, after.acceleration, 1));
            self.result.max_violation = @max(self.result.max_violation, violation);
            if (violation > tolerance) {
                self.result.feasible = false;
                self.refine[previous.section] = true;
                self.refine[cell.section] = true;
            }
            if (!std.math.isFinite(violation)) self.result.verified = false;
        }
    }

    fn impulses(self: *Context) void {
        for (self.prepared.plan.rules, 0..) |rule, index| {
            if (rule.kind() != .hard or rule.definition != .quantity) continue;
            const quantity = rule.definition.quantity.quantity;
            switch (quantity) {
                .acceleration3d, .acceleration_ecef, .forward_acceleration, .vertical_acceleration, .lateral_acceleration, .jerk3d, .forward_jerk => {},
                else => continue,
            }
            for (1..self.prepared.plan.events.len - 1) |event| {
                if (!containsEvent(self.path, rule.scope, event)) continue;
                const before = self.eventState(.{ .index = event, .side = .in });
                const after = self.eventState(.{ .index = event, .side = .out });
                const violation = switch (quantity) {
                    .acceleration3d, .acceleration_ecef => difference(before.velocity, after.velocity, 10),
                    .jerk3d => @max(difference(before.velocity, after.velocity, 10), difference(before.acceleration, after.acceleration, 1)),
                    .forward_acceleration => self.scalarJump(before, after, .forward_speed, 10),
                    .forward_jerk => @max(self.scalarJump(before, after, .forward_speed, 10), self.scalarJump(before, after, .forward_acceleration, 1)),
                    .vertical_acceleration => self.scalarJump(before, after, .climb_rate, 10),
                    .lateral_acceleration => @abs(lateralSpeed(before) - lateralSpeed(after)) / 10,
                    else => unreachable,
                };
                if (violation <= tolerance) continue;
                self.reports[index].violation = @max(self.reports[index].violation, violation);
                self.reports[index].residual = @max(@abs(self.reports[index].residual), violation);
                self.reports[index].active = true;
                self.result.max_violation = @max(self.result.max_violation, violation);
                self.result.feasible = false;
                self.refine[event - 1] = true;
                self.refine[event] = true;
                if (!std.math.isFinite(violation)) self.result.verified = false;
            }
        }
    }

    fn scalarJump(self: *const Context, before: Scalar.State, after: Scalar.State, quantity: model.Quantity, scale: f64) f64 {
        var before_point = Scalar.Point.init(before, self.path.datum, !self.path.oriented);
        var after_point = Scalar.Point.init(after, self.path.datum, !self.path.oriented);
        const a = before_point.quantity(quantity)[0];
        const b = after_point.quantity(quantity)[0];
        const delta = @abs(a - b) / scale;
        return if (std.math.isFinite(delta)) delta else std.math.inf(f64);
    }

    fn eventState(self: *const Context, event: model.EventRef) Scalar.State {
        const location = self.path.eventLocation(event);
        return self.path.state(location.index, location.u);
    }

    fn curveProgress(self: *Context) void {
        const auxiliary: rules.Check = .{ .scope = .all, .operation = .alignment };
        for (self.candidate.curves) |curve| {
            const definition = self.prepared.plan.rules[curve.rule].definition.relation.value.follow_curve;
            const samples = curve.samples;
            if (samples.len == 0) {
                self.record(auxiliary, -std.math.inf(f64), 0);
                continue;
            }
            const sign: f64 = if (definition.to >= definition.from) 1 else -1;
            const low = @min(definition.from, definition.to);
            const high = @max(definition.from, definition.to);
            for (samples, 0..) |sample, i| {
                if (!std.math.isFinite(sample.time)) {
                    self.record(auxiliary, -std.math.inf(f64), 0);
                    continue;
                }
                const location = self.path.locate(sample.time, false);
                self.record(auxiliary, sample.value - low, location.index);
                self.record(auxiliary, high - sample.value, location.index);
                if (i == 0) self.record(auxiliary, -@abs(sample.value - definition.from), location.index);
                if (i + 1 == samples.len and i != 0) self.record(auxiliary, -@abs(sample.value - definition.to), location.index);
                if (i == 0) continue;
                const previous = samples[i - 1];
                self.record(auxiliary, sample.time - previous.time, location.index);
                const delta = sample.value - previous.value;
                self.record(auxiliary, if (sample.time == previous.time) -@abs(delta) else sign * delta, location.index);
            }
        }
    }

    fn polynomial(self: *const Context, term: rules.Check, cell: usize) ?Polynomial {
        const jets = self.cells[cell];
        if (term.operation == .region) return self.regionPolynomial(term, jets.position);
        if (term.operation != .quantity) return null;
        const operation = term.operation.quantity;
        const rule = self.prepared.plan.rules[operation.rule];
        const definition = rule.definition.quantity;
        var vector = jets.position;
        const derivatives: usize = switch (definition.quantity) {
            .speed3d, .velocity_ecef => 1,
            .acceleration3d, .acceleration_ecef => 2,
            .jerk3d => 3,
            else => 0,
        };
        for (0..derivatives) |_| for (&vector) |*p| {
            p.* = p.derivative().scaled(1 / jets.duration);
        };
        if (operation.zero_norm) return switch (definition.quantity) {
            .speed3d, .acceleration3d, .jerk3d => vector[operation.component].scaled(1 / rule.scale),
            else => null,
        };

        const squared_norm = definition.quantity == .speed3d or definition.quantity == .acceleration3d or definition.quantity == .jerk3d;
        const rhs = rules.rightHand(rule, operation.comparison);
        const target = if (rhs) |value| self.rightHand(value, operation.component) else 0;
        var p: Polynomial = switch (definition.quantity) {
            .position, .velocity_ecef, .acceleration_ecef => vector[operation.component],
            .time => blk: {
                var time = Polynomial.constant(self.path.timeAt(cell, 0));
                time.degree = 1;
                time.coefficients[1] = jets.duration;
                break :blk time;
            },
            .duration => Polynomial.constant(self.path.scopeDuration(rule.scope)),
            .turn_rate => jets.course.derivative().scaled(180 / (std.math.pi * jets.duration)),
            .speed3d, .acceleration3d, .jerk3d => blk: {
                if (rule.kind() != .hard or target < 0 or rhs == null) return null;
                break :blk vector[0].square().add(vector[1].square()).add(vector[2].square());
            },
            else => return null,
        };
        if (rhs != null) {
            p = p.add(Polynomial.constant(-(if (squared_norm) target * target else target)));
            if (squared_norm) p = p.scaled(1 / (if (rhs.? == .scalar) @max(rule.scale, @abs(target)) else rule.scale));
        }
        return p.scaled((if (operation.comparison == .max) @as(f64, -1) else 1) / rule.scale);
    }

    fn rightHand(self: *const Context, value: model.Value, component: usize) f64 {
        var sampler: Sampler = .{ .candidate = self.candidate, .location = .{ .index = 0, .u = 0 } };
        return rules.value(Scalar, self.prepared, value, &sampler)[component];
    }

    fn regionPolynomial(self: *const Context, term: rules.Check, position: [3]Polynomial) Polynomial {
        const operation = term.operation.region;
        const rule = self.prepared.plan.rules[operation.rule];
        const region = self.prepared.regions[rule.definition.relation.value.inside_region];
        var east = Polynomial.constant(0);
        var north = Polynomial.constant(0);
        for (position, region.origin, region.east, region.north) |p, offset, e, n| {
            const delta = p.add(Polynomial.constant(-offset));
            east = east.add(delta.scaled(e));
            north = north.add(delta.scaled(n));
        }
        return switch (region.shape) {
            .circle => |radius| Polynomial.constant(radius * radius).add(east.square().scaled(-1)).add(north.square().scaled(-1)).scaled(1 / (@max(1, radius) * rule.scale)),
            .polygon => |edges| blk: {
                const edge = edges[operation.edge];
                break :blk north.add(Polynomial.constant(-edge.start[1])).scaled(edge.delta[0]).add(east.add(Polynomial.constant(-edge.start[0])).scaled(-edge.delta[1])).scaled(edge.inverse_length / rule.scale);
            },
        };
    }
};

fn lateralSpeed(state: Scalar.State) f64 {
    const frame = Scalar.frame(state.position);
    return Scalar.dot(frame.east, state.velocity) * @cos(state.course) - Scalar.dot(frame.north, state.velocity) * @sin(state.course);
}

fn scopedInterval(path: *const candidate_module.Path, scope: model.Scope, index: usize) ?[2]f64 {
    const cell = path.cells[index];
    switch (scope) {
        .section => |section| if (cell.section != section) return null,
        .between => |events| if (cell.section < events[0] or cell.section >= events[1]) return null,
        .time_range => |times| {
            const start = path.timeAt(index, 0);
            const duration = path.duration(cell.section) * (cell.end - cell.start);
            const low = @max(0, (times[0] - start) / duration);
            const high = @min(1, (times[1] - start) / duration);
            return if (low <= high) .{ low, high } else null;
        },
        .all => {},
        .event, .time => return null,
    }
    return .{ 0, 1 };
}

fn containsEvent(path: *const candidate_module.Path, scope: model.Scope, event: usize) bool {
    return switch (scope) {
        .all => true,
        .between => |events| event > events[0] and event < events[1],
        .time_range => |times| blk: {
            const time = path.event_times[event];
            break :blk time > times[0] and time < times[1];
        },
        else => false,
    };
}

fn difference(a: [3]f64, b: [3]f64, scale: f64) f64 {
    var result: f64 = 0;
    for (a, b) |before, after| {
        const delta = @abs(before - after) / scale;
        if (!std.math.isFinite(delta)) return std.math.inf(f64);
        result = @max(result, delta);
    }
    return result;
}

fn timeLocation(path: *const candidate_module.Path, time: f64) candidate_module.Location {
    var location = path.locate(time, true);
    location.u = (time - path.timeAt(location.index, 0)) / path.cellDuration(location.index);
    return location;
}
