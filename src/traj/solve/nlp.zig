const std = @import("std");

pub const EvalError = error{Domain};
pub const Error = std.mem.Allocator.Error;

pub const Values = struct {
    objective: *f64,
    constraints: []f64,
};

pub const Derivatives = struct {
    gradient: []f64,
    jacobian: []f64,
    soft: []f64,
    curved: []f64,
};

/// Rows are sparse and lie one after another: row `r` holds the entries `row_offsets[r]..row_offsets[r + 1]` of
/// `columns` and of the Jacobian. The soft rows are the objective's: its second derivative is taken as the sum of
/// their squares. A constraint row that curves has a few rows more over its own columns, at `curved_offsets`: its
/// second derivative is minus the sum of their squares. `order` lists the variables that are not fixed so that rows
/// couple near neighbours.
pub const Layout = struct {
    constraint_count: usize,
    equality_count: usize,
    row_offsets: []const usize,
    columns: []const usize,
    soft_offsets: []const usize,
    soft_columns: []const usize,
    curved_offsets: []const usize,
    order: []const usize,
    lower: []const f64,
    upper: []const f64,
};

/// Work is counted in evaluations of the values: an evaluation of the derivatives counts as `derivative_work` of
/// them, a factorisation with the assembly before it as `factor_work` (what each costs, measured).
pub const derivative_work = 16;
pub const factor_work = 2;

pub const Options = struct {
    feasibility_tolerance: f64 = 1e-7,
    stationarity_tolerance: f64 = 1e-6,
    complementarity_tolerance: f64 = 1e-7,
    max_outer_iterations: usize = 40,
    /// A larger cap settles a few more objectives and makes the refusal of a plan without a path slower.
    max_inner_iterations: usize = 100,
    max_work: usize = std.math.maxInt(usize),
    initial_penalty: f64 = 10,
    max_penalty: f64 = 1e12,
};

pub const Status = enum {
    converged,
    /// The rules hold, and three steps running lowered the merit by nothing to speak of.
    flat,
    iteration_limit,
    work_limit,
    stalled,
    invalid_initial,
};

pub const Report = struct {
    status: Status = .invalid_initial,
    objective: f64 = std.math.inf(f64),
    primal_violation: f64 = std.math.inf(f64),
    stationarity: f64 = std.math.inf(f64),
    complementarity: f64 = std.math.inf(f64),
    inner_iterations: usize = 0,
    work: usize = 0,
    penalty: f64,
};

/// An augmented Lagrangian whose inner problem is solved by damped Newton steps: each step minimises a quadratic
/// model of the merit (Gauss-Newton rows, and the curvature of the rows that curve) through a Cholesky factor.
pub fn solve(allocator: std.mem.Allocator, layout: Layout, evaluator: anytype, x: []f64, options: Options) Error!Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var current = try Point.init(memory, x.len, layout);
    // One set of derivatives serves both points: a trial has values only, and takes the set over when it is taken.
    var trial = current;
    trial.constraints = try memory.alloc(f64, layout.constraint_count);
    const gradient = try memory.alloc(f64, x.len);
    const candidate = try memory.alloc(f64, x.len);
    const step = try memory.alloc(f64, x.len);
    const multipliers = try memory.alloc(f64, layout.constraint_count);
    @memset(multipliers, 0);
    var model = try Model.init(allocator, memory, layout, x.len);
    defer model.deinit();
    var report: Report = .{ .penalty = options.initial_penalty };
    for (x, 0..) |*value, i| value.* = project(layout, i, value.*);
    if (!evaluateValues(evaluator, x, &current, &report) or !evaluateDerivatives(evaluator, x, &current, &report)) return report;
    measure(layout, x, current, multipliers, gradient, &report);
    if (converged(report, options)) {
        report.status = .converged;
        return report;
    }

    var previous_progress = std.math.inf(f64);
    var penalty_stalls: usize = 0;
    var stuck: usize = 0;
    var damping: f64 = 1e-4;
    for (0..options.max_outer_iterations) |_| {
        const steps = report.inner_iterations;
        const inner_tolerance = @max(options.stationarity_tolerance, @min(1e-2, previous_progress * 0.1));
        var merit = augmentedObjective(layout, current, multipliers, report.penalty);
        augmentedGradient(layout, current, multipliers, report.penalty, gradient);
        // The inner solve ends at its tolerance, or when three steps running have gained nothing to speak of: one
        // step may gain little only for being short, after a damping that has just grown.
        var flat: usize = 0;
        var settled = false;
        for (0..options.max_inner_iterations + 1) |inner| {
            settled = flat == 3 or projectedNorm(layout, x, gradient) <= inner_tolerance;
            if (settled or inner == options.max_inner_iterations) break;
            report.inner_iterations += 1;
            model.begin(layout, x, current, multipliers, report.penalty, gradient);
            var growth: f64 = 2;
            var rounds: usize = 0;
            const accepted: ?f64 = while (damping <= 1e12) {
                if (report.work >= options.max_work) {
                    measure(layout, x, current, multipliers, step, &report);
                    report.status = .work_limit;
                    return report;
                }
                try model.assemble(layout, current, multipliers, report.penalty);
                report.work += factor_work;
                if (!model.factorize(damping)) {
                    damping *= 10;
                    continue;
                }
                model.solve(step);
                // A step that changes which limits the model holds active is taken again with those: it may not
                // run through a limit that was slack where it began. Six times at the most: a set that still
                // changes then may go round for ever, and the merit judges the step as it stands.
                const forecast = model.predict(layout, current, multipliers, report.penalty, step);
                if (forecast.changed and rounds < 6) {
                    rounds += 1;
                    continue;
                }
                rounds = 0;
                var slope: f64 = 0;
                var moved = false;
                for (candidate, x, step, gradient, 0..) |*value, old, d, g, i| {
                    value.* = project(layout, i, old + d);
                    slope += g * (value.* - old);
                    moved = moved or value.* != old;
                }
                if (!moved) break null;
                if (slope < 0 and forecast.fall > 0 and evaluateValues(evaluator, candidate, &trial, &report)) {
                    const value = augmentedObjective(layout, trial, multipliers, report.penalty);
                    if (std.math.isFinite(value) and value <= merit + 1e-4 * slope) {
                        if (evaluateDerivatives(evaluator, candidate, &trial, &report)) {
                            // The damping follows the fall of the merit against the fall foretold (Nielsen's rule).
                            const gain = 2 * (merit - value) / forecast.fall - 1;
                            damping = @max(1e-12, damping * @max(1.0 / 3.0, 1 - gain * gain * gain));
                            break value;
                        }
                        _ = evaluateDerivatives(evaluator, x, &current, &report);
                    }
                }
                damping *= growth;
                growth *= 2;
                model.activate(layout, current, multipliers, report.penalty);
            } else null;
            const value = accepted orelse {
                measure(layout, x, current, multipliers, step, &report);
                report.status = .stalled;
                return report;
            };
            // Nothing to speak of is 1e-9 of the merit (of one, where the merit is less): all the steps the options
            // allow, each gaining that, would not gain a hundred-thousandth of it.
            flat = if (merit - value <= 1e-9 * @max(1, @abs(value))) flat + 1 else 0;
            merit = value;
            @memcpy(x, candidate);
            std.mem.swap(Point, &current, &trial);
            augmentedGradient(layout, current, multipliers, report.penalty, gradient);
            if (zeroMultipliers(layout, x, current, multipliers, step, options, &report)) return report;
        }

        var progress: f64 = 0;
        for (current.constraints, multipliers, 0..) |c, *lambda, row| {
            if (row < layout.equality_count) {
                progress = @max(progress, @abs(c));
                lambda.* = std.math.clamp(lambda.* + report.penalty * c, -1e12, 1e12);
            } else {
                progress = @max(progress, @abs(@min(c, lambda.* / report.penalty)));
                lambda.* = std.math.clamp(lambda.* - report.penalty * c, 0, 1e12);
            }
        }
        measure(layout, x, current, multipliers, gradient, &report);
        if (converged(report, options)) {
            report.status = .converged;
            return report;
        }
        // The rules hold and the objective neither settles nor gains: more of the same would not change that.
        if ((flat == 3 or !settled) and report.primal_violation <= options.feasibility_tolerance) {
            report.status = if (settled) .flat else .iteration_limit;
            return report;
        }
        if (progress > 0.25 * previous_progress) {
            const next_penalty = @min(options.max_penalty, report.penalty * 10);
            if (next_penalty == report.penalty) {
                penalty_stalls += 1;
            } else {
                penalty_stalls = 0;
            }
            report.penalty = next_penalty;
        } else {
            penalty_stalls = 0;
        }
        // Where the rules can be met, ten times the penalty brings what is broken down tenfold or more. An inner
        // solve that settles with over 0.9 of what the one before it left has gained next to nothing; after three
        // such running the penalty has risen a hundredfold for less than a fifth off, and the rules are given up.
        // An inner solve that took no step says nothing: its point is stationary under this penalty, and a larger
        // one may show a way out.
        if (report.inner_iterations > steps) stuck = if (settled and progress > 0.9 * previous_progress and report.primal_violation > options.feasibility_tolerance) stuck + 1 else 0;
        if (penalty_stalls >= 3 or stuck == 3) {
            report.status = .stalled;
            return report;
        }
        previous_progress = progress;
    }
    report.status = .iteration_limit;
    return report;
}

const Point = struct {
    objective: f64 = 0,
    gradient: []f64,
    constraints: []f64,
    jacobian: []f64,
    soft: []f64,
    curved: []f64,

    fn init(allocator: std.mem.Allocator, n: usize, layout: Layout) Error!Point {
        return .{
            .gradient = try allocator.alloc(f64, n),
            .constraints = try allocator.alloc(f64, layout.constraint_count),
            .jacobian = try allocator.alloc(f64, layout.columns.len),
            .soft = try allocator.alloc(f64, layout.soft_columns.len),
            .curved = try allocator.alloc(f64, layout.curved_offsets[layout.constraint_count]),
        };
    }
};

/// The quadratic model of the merit about a point, over the layout's order: its matrix, kept by rows from each
/// row's first coupled unknown to its diagonal (a profile), the Cholesky factor of the damped matrix, and minus the
/// model's gradient. The inequality rows the model holds active are its own: they begin as the merit's and follow
/// the step. A variable held at a bound is a row of the identity.
const Model = struct {
    allocator: std.mem.Allocator,
    order: []const usize,
    position: []usize,
    free: []bool,
    active: []bool,
    first: []usize,
    start: []usize,
    places: []usize,
    entries: []f64,
    rhs: []f64,
    work: []f64,
    matrix: []f64 = &.{},
    factor: []f64 = &.{},
    size: usize = 0,
    scale: f64 = 1,

    fn init(allocator: std.mem.Allocator, arena: std.mem.Allocator, layout: Layout, n: usize) Error!Model {
        const count = layout.order.len;
        const position = try arena.alloc(usize, n);
        // Filled for the variables of the order alone: the layout gives no row a fixed variable for a column.
        for (layout.order, 0..) |column, place| position[column] = place;
        var longest: usize = 0;
        for ([_][]const usize{ layout.row_offsets, layout.soft_offsets }) |offsets| {
            for (offsets[0 .. offsets.len - 1], offsets[1..]) |a, b| longest = @max(longest, b - a);
        }
        return .{
            .allocator = allocator,
            .order = layout.order,
            .position = position,
            .free = try arena.alloc(bool, count),
            .active = try arena.alloc(bool, layout.constraint_count),
            .first = try arena.alloc(usize, count),
            .start = try arena.alloc(usize, count),
            .places = try arena.alloc(usize, longest),
            .entries = try arena.alloc(f64, longest),
            .rhs = try arena.alloc(f64, count),
            .work = try arena.alloc(f64, count),
        };
    }

    fn deinit(self: *Model) void {
        self.allocator.free(self.matrix);
        self.allocator.free(self.factor);
    }

    /// Where a step begins: the variables it may move, and the rows the merit holds active there.
    fn begin(self: *Model, layout: Layout, x: []const f64, point: Point, multipliers: []const f64, penalty: f64, gradient: []const f64) void {
        for (self.order, self.free) |column, *free| free.* = freeVariable(layout, column, x[column], gradient[column]);
        self.activate(layout, point, multipliers, penalty);
    }

    fn activate(self: *Model, layout: Layout, point: Point, multipliers: []const f64, penalty: f64) void {
        for (self.active, point.constraints, multipliers, 0..) |*active, c, lambda, row| active.* = row < layout.equality_count or lambda - penalty * c > 0;
    }

    fn assemble(self: *Model, layout: Layout, point: Point, multipliers: []const f64, penalty: f64) Error!void {
        for (self.first, 0..) |*first, place| first.* = place;
        // Twice over the rows: the first time each widens the profile, the second it adds its square.
        inline for (.{ false, true }) |fill| {
            for (layout.soft_offsets[0 .. layout.soft_offsets.len - 1], layout.soft_offsets[1..]) |a, b| self.add(layout.soft_columns[a..b], point.soft[a..b], 1, fill);
            for (point.constraints, multipliers, self.active, 0..) |c, lambda, active, row| {
                if (!active) continue;
                const columns = layout.columns[layout.row_offsets[row]..layout.row_offsets[row + 1]];
                const jacobian = point.jacobian[layout.row_offsets[row]..layout.row_offsets[row + 1]];
                self.add(columns, jacobian, penalty, fill);
                const pull = if (row < layout.equality_count) lambda + penalty * c else penalty * c - lambda;
                if (fill) for (columns, jacobian) |column, value| {
                    self.rhs[self.position[column]] -= pull * value;
                };
                // An inequality row that pushes back curves the merit by its push times its own curvature.
                if (row < layout.equality_count or pull >= 0) continue;
                var at = layout.curved_offsets[row];
                while (at < layout.curved_offsets[row + 1]) : (at += columns.len) self.add(columns, point.curved[at..][0..columns.len], -pull, fill);
            }
            if (fill) continue;
            for (self.order, self.rhs) |column, *value| value.* = -point.gradient[column];
            self.size = 0;
            for (self.first, self.start, 0..) |first, *start, place| {
                start.* = self.size;
                self.size += place - first + 1;
            }
            if (self.size > self.matrix.len) {
                self.matrix = try self.allocator.realloc(self.matrix, self.size);
                self.factor = try self.allocator.realloc(self.factor, self.size);
            }
            @memset(self.matrix[0..self.size], 0);
        }
        // The damping is relative to the largest diagonal entry, and to one where that is less: where no row is held
        // and no soft term curves, the diagonal is rounding noise, and a damping relative to it would damp nothing.
        self.scale = 1;
        for (self.first, self.start, 0..) |first, start, place| self.scale = @max(self.scale, self.matrix[start + place - first]);
    }

    fn add(self: *Model, columns: []const usize, values: []const f64, weight: f64, fill: bool) void {
        var count: usize = 0;
        var lowest: usize = std.math.maxInt(usize);
        for (columns, values) |column, value| {
            const place = self.position[column];
            if (value == 0 or !self.free[place]) continue;
            self.places[count] = place;
            self.entries[count] = value;
            count += 1;
            lowest = @min(lowest, place);
        }
        for (self.places[0..count], self.entries[0..count], 0..) |a, va, index| {
            if (!fill) {
                self.first[a] = @min(self.first[a], lowest);
                continue;
            }
            for (self.places[0 .. index + 1], self.entries[0 .. index + 1]) |b, vb| {
                const row = @max(a, b);
                self.matrix[self.start[row] + @min(a, b) - self.first[row]] += weight * va * vb;
            }
        }
    }

    /// The factor of the matrix with `damping` times `scale` added to the diagonal; false when that is not positive
    /// definite to rounding.
    fn factorize(self: *Model, damping: f64) bool {
        const l = self.factor[0..self.size];
        @memcpy(l, self.matrix[0..self.size]);
        for (self.first, self.start, self.free, 0..) |first, start, free, i| {
            const row = l[start..][0 .. i - first + 1];
            for (first..i) |j| {
                const other = l[self.start[j]..][0 .. j - self.first[j] + 1];
                const from = @max(first, self.first[j]);
                row[j - first] = (row[j - first] - dot(row[from - first .. j - first], other[from - self.first[j] .. j - self.first[j]])) / other[j - self.first[j]];
            }
            const diagonal = row[i - first] + (if (free) damping * self.scale else 1) - dot(row[0 .. i - first], row[0 .. i - first]);
            if (!(diagonal > 0)) return false;
            row[i - first] = @sqrt(diagonal);
        }
        return true;
    }

    /// The step that minimises the damped model: zero where a variable is held.
    fn solve(self: *Model, step: []f64) void {
        const w = self.work;
        for (self.rhs, self.free, w) |rhs, free, *value| value.* = if (free) rhs else 0;
        for (self.first, self.start, 0..) |first, start, i| {
            const row = self.factor[start..][0 .. i - first + 1];
            w[i] = (w[i] - dot(row[0 .. i - first], w[first..i])) / row[i - first];
        }
        var i = w.len;
        while (i > 0) {
            i -= 1;
            const first = self.first[i];
            const row = self.factor[self.start[i]..][0 .. i - first + 1];
            w[i] /= row[i - first];
            for (row[0 .. i - first], w[first..i]) |entry, *value| value.* -= entry * w[i];
        }
        @memset(step, 0);
        for (self.order, w) |column, value| step[column] = value;
    }

    /// How far the model foretells the merit to fall by a step. The model's active rows move to those the step
    /// leaves active (a row that curves is foretold with its curvature), and `changed` says whether they did.
    fn predict(self: *Model, layout: Layout, point: Point, multipliers: []const f64, penalty: f64, step: []const f64) struct { changed: bool, fall: f64 } {
        var rise = dot(point.gradient, step);
        for (layout.soft_offsets[0 .. layout.soft_offsets.len - 1], layout.soft_offsets[1..]) |a, b| {
            const s = along(layout.soft_columns[a..b], point.soft[a..b], step);
            rise += 0.5 * s * s;
        }
        var changed = false;
        for (point.constraints, multipliers, self.active, 0..) |c, lambda, *active, row| {
            const columns = layout.columns[layout.row_offsets[row]..layout.row_offsets[row + 1]];
            var s = along(columns, point.jacobian[layout.row_offsets[row]..layout.row_offsets[row + 1]], step);
            if (row < layout.equality_count) {
                rise += (lambda + penalty * c) * s + 0.5 * penalty * s * s;
                continue;
            }
            var at = layout.curved_offsets[row];
            while (at < layout.curved_offsets[row + 1]) : (at += columns.len) {
                const bend = along(columns, point.curved[at..][0..columns.len], step);
                s -= 0.5 * bend * bend;
            }
            const now = lambda - penalty * (c + s) > 0;
            changed = changed or now != active.*;
            active.* = now;
            rise += hinge(c + s, lambda, penalty) - hinge(c, lambda, penalty);
        }
        return .{ .changed = changed, .fall = -rise };
    }
};

fn evaluateValues(evaluator: anytype, x: []const f64, point: *Point, report: *Report) bool {
    report.work += 1;
    const result: EvalError!void = evaluator.values(x, .{
        .objective = &point.objective,
        .constraints = point.constraints,
    });
    result catch return false;
    if (!std.math.isFinite(point.objective)) return false;
    for (point.constraints) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn evaluateDerivatives(evaluator: anytype, x: []const f64, point: *Point, report: *Report) bool {
    report.work += derivative_work;
    const result: EvalError!void = evaluator.derivatives(x, .{
        .gradient = point.gradient,
        .jacobian = point.jacobian,
        .soft = point.soft,
        .curved = point.curved,
    });
    result catch return false;
    for ([_][]const f64{ point.gradient, point.jacobian, point.soft, point.curved }) |values| {
        for (values) |value| if (!std.math.isFinite(value)) return false;
    }
    return true;
}

/// The augmented Lagrangian's term of an inequality row.
fn hinge(c: f64, lambda: f64, penalty: f64) f64 {
    return if (lambda - penalty * c > 0) -lambda * c + 0.5 * penalty * c * c else -0.5 * lambda * (lambda / penalty);
}

fn augmentedObjective(layout: Layout, point: Point, multipliers: []const f64, penalty: f64) f64 {
    var objective = point.objective;
    for (point.constraints, multipliers, 0..) |c, lambda, row| {
        objective += if (row < layout.equality_count) lambda * c + 0.5 * penalty * c * c else hinge(c, lambda, penalty);
    }
    return objective;
}

fn augmentedGradient(layout: Layout, point: Point, multipliers: []const f64, penalty: f64, gradient: []f64) void {
    @memcpy(gradient, point.gradient);
    for (point.constraints, multipliers, 0..) |c, lambda, row| {
        const weight = if (row < layout.equality_count) lambda + penalty * c else -@max(0, lambda - penalty * c);
        addRow(layout, point.jacobian, row, weight, gradient);
    }
}

fn measure(layout: Layout, x: []const f64, point: Point, multipliers: []const f64, gradient: []f64, report: *Report) void {
    report.objective = point.objective;
    report.primal_violation = 0;
    report.complementarity = 0;
    @memcpy(gradient, point.gradient);
    for (point.constraints, multipliers, 0..) |c, lambda, row| {
        if (row < layout.equality_count) {
            report.primal_violation = @max(report.primal_violation, @abs(c));
            addRow(layout, point.jacobian, row, lambda, gradient);
        } else {
            report.primal_violation = @max(report.primal_violation, -c);
            report.complementarity = @max(report.complementarity, @abs(lambda * c));
            addRow(layout, point.jacobian, row, -lambda, gradient);
        }
    }
    report.stationarity = projectedNorm(layout, x, gradient);
}

fn converged(report: Report, options: Options) bool {
    return std.math.isFinite(report.objective) and report.primal_violation <= options.feasibility_tolerance and report.stationarity <= options.stationarity_tolerance and report.complementarity <= options.complementarity_tolerance;
}

fn zeroMultipliers(layout: Layout, x: []const f64, point: Point, multipliers: []f64, gradient: []f64, options: Options, report: *Report) bool {
    if (projectedNorm(layout, x, point.gradient) > options.stationarity_tolerance) return false;
    for (point.constraints, 0..) |c, row| {
        const violation = if (row < layout.equality_count) @abs(c) else @max(0, -c);
        if (violation > options.feasibility_tolerance) return false;
    }
    @memset(multipliers, 0);
    measure(layout, x, point, multipliers, gradient, report);
    if (!converged(report.*, options)) return false;
    report.status = .converged;
    return true;
}

fn addRow(layout: Layout, jacobian: []const f64, row: usize, weight: f64, gradient: []f64) void {
    for (layout.row_offsets[row]..layout.row_offsets[row + 1]) |entry| gradient[layout.columns[entry]] += weight * jacobian[entry];
}

fn projectedNorm(layout: Layout, x: []const f64, gradient: []const f64) f64 {
    var norm: f64 = 0;
    for (x, gradient, 0..) |value, g, i| {
        if (!std.math.isFinite(g)) return std.math.inf(f64);
        norm = @max(norm, @abs(value - project(layout, i, value - g)));
    }
    return norm;
}

fn project(layout: Layout, index: usize, value: f64) f64 {
    return std.math.clamp(value, layout.lower[index], layout.upper[index]);
}

fn freeVariable(layout: Layout, index: usize, value: f64, gradient: f64) bool {
    if (value <= layout.lower[index] and gradient >= 0) return false;
    if (value >= layout.upper[index] and gradient <= 0) return false;
    return true;
}

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += x * y;
    return sum;
}

/// A sparse row along a step.
fn along(columns: []const usize, values: []const f64, step: []const f64) f64 {
    var sum: f64 = 0;
    for (columns, values) |column, value| sum += value * step[column];
    return sum;
}
