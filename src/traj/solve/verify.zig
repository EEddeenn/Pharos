const std = @import("std");
const core = @import("shared").core;
const trajectory = @import("shared").trajectory;
const model = @import("../plan.zig").model;
const quantities = @import("../plan.zig").quantities;
const rules = @import("rules.zig");
const candidate_module = @import("candidate.zig");
const Scalar = @import("kernel.zig").Scalar;
const polynomials = @import("verify/polynomial.zig");
const Polynomial = polynomials.Polynomial;
const bounds = polynomials.bounds;
const bound_accuracy = polynomials.bound_accuracy;

pub const tolerance: f64 = 1e-5;
/// The stretches of a cell that a check which is no polynomial begins with: `adaptive` halves those it cannot pass.
const stretches = 16;

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
    /// For each rule that is not met because it asks for a direction of travel where the path is at rest (at its one
    /// point; an equality, throughout its interval): a time of that rest.
    rests: []const ?f64,
    refine_sections: []const bool,
};

pub fn check(arena: std.mem.Allocator, prepared: *const rules.Prepared, candidate: *const candidate_module.Candidate) !Result {
    const reports = try arena.alloc(RuleReport, prepared.plan.rules.len);
    for (reports, prepared.plan.rules) |*report, rule| report.* = .{ .id = rule.id, .kind = rule.kind(), .violation = 0, .residual = 0, .active = false };
    const rests = try arena.alloc(?f64, reports.len);
    @memset(rests, null);
    const refine = try arena.alloc(bool, prepared.plan.sections.len);
    @memset(refine, false);
    const seen = try arena.alloc(bool, reports.len);
    @memset(seen, false);
    const cells = try arena.alloc(polynomials.CellPolynomials, candidate.path.cells.len);
    for (cells, 0..) |*cell, index| cell.* = .init(&candidate.path, index);
    var result: Result = .{ .feasible = true, .verified = true, .max_violation = 0, .rules = reports, .rests = rests, .refine_sections = refine };
    var context: Context = .{ .prepared = prepared, .candidate = candidate, .path = &candidate.path, .cells = cells, .result = &result, .reports = reports, .rests = rests, .refine = refine, .seen = seen };
    context.domainBounds();
    context.continuity();
    context.curveProgress();
    for (prepared.checks) |check_of_rule| {
        var term = check_of_rule;
        // A soft norm is split for the optimiser alone: it is reported whole, once.
        if (term.operation == .quantity and term.operation.quantity.split_norm and prepared.isObjective(term)) {
            if (term.operation.quantity.component != 0) continue;
            term.operation.quantity.split_norm = false;
        }
        // A least value of a norm at or under zero holds whatever the path: there is nothing to settle.
        if (rules.kindOf(prepared, term) == .vacuous) continue;
        // A course held over an interval is the optimiser's row along it as well; the course itself is the verifier's.
        if (term.operation == .ahead and term.scope != .event) continue;
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
    // A rule of a direction of travel holds wherever the path moves. Where the path is at rest a limit holds. An
    // equality, a target and an objective are not met where it is at rest at their one point; over an interval in
    // which the path moves nowhere an equality is not met either, and a soft rule holds. No finer mesh mends what
    // is not met.
    for (prepared.plan.rules, reports, rests, seen) |rule, *report, *rest, moved| {
        if (rest.* == null) continue;
        const comparison = rule.definition.quantity.comparison;
        if (comparison == .range or (quantities.interval(rule.scope) and (moved or comparison != .eq))) {
            rest.* = null;
            continue;
        }
        report.violation = std.math.inf(f64);
        report.residual = std.math.inf(f64);
        result.max_violation = std.math.inf(f64);
        result.feasible = false;
        result.verified = false;
    }
    for (reports) |*report| {
        if (!std.math.isFinite(report.violation)) report.violation = 1e300;
        if (!std.math.isFinite(report.residual)) report.residual = if (report.residual < 0) -1e300 else 1e300;
    }
    return result;
}

const Sampler = struct {
    prepared: *const rules.Prepared,
    candidate: *const candidate_module.Candidate,
    location: candidate_module.Location,
    cached: ?Scalar.Point = null,
    requested_time: ?f64 = null,

    pub fn point(self: *Sampler) *Scalar.Point {
        if (self.cached == null) {
            const path = &self.candidate.path;
            self.cached = Scalar.Point.init(path.state(self.location.index, self.location.u), path.datum);
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
        var sampler: Sampler = .{ .prepared = self.prepared, .candidate = self.candidate, .location = self.candidate.path.eventLocation(event) };
        return sampler.quantity(q, .{ .event = event });
    }

    pub fn atRest(self: *const Sampler, event: model.EventRef) bool {
        var sampler: Sampler = .{ .prepared = self.prepared, .candidate = self.candidate, .location = self.candidate.path.eventLocation(event) };
        return sampler.point().atRest();
    }

    /// A guide is held against the curve, not against the one point of it that the candidate names at this time:
    /// the progress is that of the curve's nearest point, sought by golden section from the candidate's own two
    /// samples around this time to as far again on either side of them, within the rule's stretch of the curve.
    pub fn progress(self: *Sampler, rule: usize) f64 {
        const time = self.candidate.path.timeAt(self.location.index, self.location.u);
        const around = self.candidate.progressAround(rule, time) orelse return std.math.nan(f64);
        const named = if (around[1].time == time or around[0].time == around[1].time) around[1].value else around[0].value + (around[1].value - around[0].value) * (time - around[0].time) / (around[1].time - around[0].time);
        if (!std.math.isFinite(named)) return named;
        const follow = self.prepared.plan.rules[rule].definition.relation.value.follow_curve;
        const span = @abs(around[1].value - around[0].value);
        var low = @max(@min(follow.from, follow.to), @min(around[0].value, around[1].value) - span);
        var high = @min(@max(follow.from, follow.to), @max(around[0].value, around[1].value) + span);
        if (!(high > low)) return named;
        const curve = self.prepared.curves[follow.curve];
        const position = self.point().state.position;
        const golden = 0.3819660112501051;
        var a = low + (high - low) * golden;
        var b = high - (high - low) * golden;
        var fa = separation(curve, position, a);
        var fb = separation(curve, position, b);
        // Forty-eight steps leave 1e-10 of the window, a micrometre of ten kilometres of guide: an exact follow is
        // held to ten micrometres, and the search must not be what it fails by.
        for (0..48) |_| {
            if (fa < fb) {
                high = b;
                b = a;
                fb = fa;
                a = low + (high - low) * golden;
                fa = separation(curve, position, a);
            } else {
                low = a;
                a = b;
                fa = fb;
                b = high - (high - low) * golden;
                fb = separation(curve, position, b);
            }
        }
        return if (@min(fa, fb) <= separation(curve, position, named)) (if (fa < fb) a else b) else named;
    }

    fn separation(curve: rules.Curve, position: [3]f64, progress_value: f64) f64 {
        const reference = rules.curveAt(Scalar, curve, progress_value);
        var sum: f64 = 0;
        for (position, reference) |p, q| sum += (p - q) * (p - q);
        return sum;
    }
};

const Context = struct {
    prepared: *const rules.Prepared,
    candidate: *const candidate_module.Candidate,
    path: *const candidate_module.Path,
    cells: []const polynomials.CellPolynomials,
    result: *Result,
    reports: []RuleReport,
    rests: []?f64,
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
        const residual = self.residualAt(term, location) orelse {
            self.rests[term.operation.quantity.rule] = self.path.timeAt(location.index, location.u);
            return;
        };
        self.record(term, residual, location.index);
    }

    /// Null where the check is of a direction of travel and the path is at rest: there it has no value.
    fn residualAt(self: *const Context, term: rules.Check, location: candidate_module.Location) ?f64 {
        var sampler: Sampler = .{ .prepared = self.prepared, .candidate = self.candidate, .location = location, .requested_time = if (term.scope == .time) term.scope.time else null };
        if (term.operation == .quantity and quantities.directed(self.prepared.plan.rules[term.operation.quantity.rule].definition.quantity.quantity) and sampler.point().atRest()) return null;
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
        var left = self.at(term, cell, start);
        for (0..stretches) |i| {
            const a = start + (end - start) * @as(f64, @floatFromInt(i)) / stretches;
            const b = start + (end - start) * @as(f64, @floatFromInt(i + 1)) / stretches;
            const right = self.at(term, cell, b);
            self.adaptive(term, cell, a, b, left, right, 0);
            left = right;
        }
    }

    fn at(self: *Context, term: rules.Check, cell: usize, u: f64) ?f64 {
        const value = self.residualAt(term, .{ .index = cell, .u = u }) orelse {
            const rest = &self.rests[term.operation.quantity.rule];
            if (rest.* == null) rest.* = self.path.timeAt(cell, u);
            return null;
        };
        self.record(term, value, cell);
        return value;
    }

    /// Over an interval a rule of a direction of travel holds wherever the path moves. A stretch that is at rest
    /// throughout holds nothing; an end at rest, where the path sets out or comes to a stand, counts as the point
    /// next to it. A stretch the path rests inside, or slows much inside (`dips`), is halved until its points tell
    /// where; at the last halving it holds at its points that move.
    fn adaptive(self: *Context, term: rules.Check, cell: usize, a: f64, b: f64, from: ?f64, to: ?f64, depth: usize) void {
        const midpoint = (a + b) * 0.5;
        const last = @as(usize, stretches) << @intCast(depth) >= 1024;
        const centre = self.at(term, cell, midpoint);
        const near = self.at(term, cell, a * 0.75 + b * 0.25);
        const far = self.at(term, cell, a * 0.25 + b * 0.75);
        if (from == null and to == null and centre == null and near == null and far == null) return;
        const inside = centre != null and near != null and far != null;
        if (self.isHard(term) and !last and (!inside or self.dips(term, cell, a, b, from != null, to != null))) {
            self.adaptive(term, cell, a, midpoint, from, centre, depth + 1);
            self.adaptive(term, cell, midpoint, b, centre, to, depth + 1);
            return;
        }
        if (!inside) return;
        const middle = centre.?;
        const quarter = near.?;
        const three_quarters = far.?;
        const left = from orelse quarter;
        const right = to orelse three_quarters;
        if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(middle) or !std.math.isFinite(quarter) or !std.math.isFinite(three_quarters)) {
            self.unresolved(cell);
            return;
        }
        if (!self.isHard(term)) return;
        if (self.straightens(term, cell, a, b)) {
            self.unresolved(cell);
            return;
        }
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
        if (last) {
            self.unresolved(cell);
            return;
        }
        self.adaptive(term, cell, a, midpoint, from, centre, depth + 1);
        self.adaptive(term, cell, midpoint, b, centre, to, depth + 1);
    }

    /// Whether, under a limit of the turn radius, the turn rate changes sign between two of a stretch's points that
    /// move. The radius is the speed over that rate: where the rate passes zero it passes every bound, for a time
    /// too short for the stretch's points to show.
    fn straightens(self: *const Context, term: rules.Check, cell: usize, a: f64, b: f64) bool {
        if (term.operation != .quantity or term.equality or self.prepared.plan.rules[term.operation.quantity.rule].definition.quantity.quantity != .turn_radius) return false;
        var before: f64 = 0;
        for (0..5) |i| {
            var here = Scalar.Point.init(self.path.state(cell, a + (b - a) * @as(f64, @floatFromInt(i)) / 4), self.path.datum);
            if (here.atRest()) continue;
            const rate = here.quantity(.turn_rate)[0];
            if (rate * before < 0) return true;
            if (rate != 0) before = rate;
        }
        return false;
    }

    /// Whether, inside a stretch that a rule of a direction of travel is held over, the horizontal speed or the
    /// distance from the Earth's axis falls to under half of the least at the stretch's points that move. A direction
    /// of travel turns as fast as either is small: between the points of such a stretch, faster than they show. The
    /// horizontal is taken across the up of the stretch's middle, and both are bounded as the polynomials they are.
    fn dips(self: *const Context, term: rules.Check, cell: usize, a: f64, b: f64, from: bool, to: bool) bool {
        if (term.operation != .quantity or !quantities.directed(self.prepared.plan.rules[term.operation.quantity.rule].definition.quantity.quantity)) return false;
        const jets = self.cells[cell];
        const up = Scalar.frame(self.path.state(cell, (a + b) * 0.5).position).up;
        var speed = Polynomial.constant(0);
        var climb = Polynomial.constant(0);
        for (jets.position, up) |p, along| {
            const velocity = p.derivative();
            speed = speed.add(velocity.square());
            climb = climb.add(velocity.scaled(along));
        }
        for ([_]Polynomial{ speed.add(climb.square().scaled(-1)), jets.position[0].square().add(jets.position[1].square()) }) |p| {
            var least = @min(p.at((a + b) * 0.5), @min(p.at(a * 0.75 + b * 0.25), p.at(a * 0.25 + b * 0.75)));
            if (from) least = @min(least, p.at(a));
            if (to) least = @min(least, p.at(b));
            if (least > 0 and bounds(p.scaled(1 / least), a, b).lower < 0.25) return true;
        }
        return false;
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
                .acceleration3d, .acceleration_ecef, .forward_acceleration, .vertical_acceleration, .lateral_acceleration, .turn_rate, .turn_radius, .jerk3d, .forward_jerk => {},
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
                    .lateral_acceleration, .turn_rate, .turn_radius => lateralStep(before, after, self.path.datum) / 10,
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
        var before_point = Scalar.Point.init(before, self.path.datum);
        var after_point = Scalar.Point.init(after, self.path.datum);
        if (quantities.directed(quantity) and (before_point.atRest() or after_point.atRest())) return 0;
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
        // What a guide's progress is held to is recorded under a check of no rule: which one it is has no part.
        const auxiliary: rules.Check = .{ .scope = .all, .operation = .maximum_duration };
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
                if (i == 0 and samples.len > 1) self.record(auxiliary, -@abs(sample.value - definition.from), location.index);
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
        if (operation.split_norm) return switch (definition.quantity) {
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
            .speed3d, .acceleration3d, .jerk3d => blk: {
                if (rule.kind() != .hard or target < 0 or rhs == null) return null;
                break :blk vector[0].square().add(vector[1].square()).add(vector[2].square());
            },
            else => return null,
        };
        if (rhs != null) {
            p = p.add(Polynomial.constant(-(if (squared_norm) target * target else target)));
            // The norm held on its own scale: a tolerance on its square over 2b + tolerance is the tolerance on it.
            if (squared_norm) p = p.scaled(1 / (2 * @abs(target) + tolerance * rule.scale));
        }
        return p.scaled((if (operation.comparison == .max) @as(f64, -1) else 1) / rule.scale);
    }

    fn rightHand(self: *const Context, value: model.Value, component: usize) f64 {
        var sampler: Sampler = .{ .prepared = self.prepared, .candidate = self.candidate, .location = .{ .index = 0, .u = 0 } };
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

/// The part of a step of the velocity at an event that is across the direction of travel: none where a side is at
/// rest, and all of the slower side's speed where the path turns by more than a right angle (a turn straight back
/// has nothing across it, and is the sharpest of all).
fn lateralStep(before: Scalar.State, after: Scalar.State, datum: model.Altitude) f64 {
    var from = Scalar.Point.init(before, datum);
    var to = Scalar.Point.init(after, datum);
    if (from.atRest() or to.atRest()) return 0;
    const a = from.horizontalVelocity();
    const b = to.horizontalVelocity();
    const speeds = [2]f64{ std.math.hypot(a[0], a[1]), std.math.hypot(b[0], b[1]) };
    if (a[0] * b[0] + a[1] * b[1] < 0) return @min(speeds[0], speeds[1]);
    return @abs(a[0] * b[1] - a[1] * b[0]) / @max(speeds[0], speeds[1]);
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
