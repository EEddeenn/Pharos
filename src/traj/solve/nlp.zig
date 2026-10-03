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
};

pub const Layout = struct {
    constraint_count: usize,
    equality_count: usize,
    row_offsets: []const usize,
    columns: []const usize,
    lower: []const f64,
    upper: []const f64,
};

pub const Options = struct {
    feasibility_tolerance: f64 = 1e-7,
    stationarity_tolerance: f64 = 1e-6,
    complementarity_tolerance: f64 = 1e-7,
    max_outer_iterations: usize = 40,
    max_inner_iterations: usize = 300,
    max_evaluations: usize = 30000,
    initial_penalty: f64 = 10,
    max_penalty: f64 = 1e12,
};

pub const Status = enum {
    converged,
    iteration_limit,
    evaluation_limit,
    stalled,
    invalid_initial,
};

pub const Report = struct {
    status: Status,
    objective: f64,
    primal_violation: f64,
    stationarity: f64,
    complementarity: f64,
    outer_iterations: usize,
    inner_iterations: usize,
    evaluations: usize,
    penalty: f64,
};

pub fn solve(allocator: std.mem.Allocator, layout: Layout, evaluator: anytype, x: []f64, options: Options) Error!Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var current = try Point.init(memory, x.len, layout);
    var trial = try Point.init(memory, x.len, layout);
    var augmented_gradient = try memory.alloc(f64, x.len);
    var trial_gradient = try memory.alloc(f64, x.len);
    const candidate = try memory.alloc(f64, x.len);
    const direction = try memory.alloc(f64, x.len);
    const multipliers = try memory.alloc(f64, layout.constraint_count);
    @memset(multipliers, 0);
    var history = try History.init(memory, x.len);
    var report: Report = .{
        .status = .invalid_initial,
        .objective = std.math.inf(f64),
        .primal_violation = std.math.inf(f64),
        .stationarity = std.math.inf(f64),
        .complementarity = std.math.inf(f64),
        .outer_iterations = 0,
        .inner_iterations = 0,
        .evaluations = 0,
        .penalty = options.initial_penalty,
    };
    for (x, 0..) |*value, i| value.* = project(layout, i, value.*);
    if (!evaluateValues(evaluator, x, &current, &report.evaluations) or !evaluateDerivatives(evaluator, x, &current)) return report;
    measure(layout, x, current, multipliers, augmented_gradient, &report);
    if (converged(report, options)) {
        report.status = .converged;
        return report;
    }

    var previous_progress = std.math.inf(f64);
    var penalty_stalls: usize = 0;
    var restart = true;
    for (0..options.max_outer_iterations) |outer| {
        report.outer_iterations = outer + 1;
        if (restart) history.clear();
        restart = false;
        const inner_tolerance = @max(options.stationarity_tolerance, @min(1e-2, previous_progress * 0.1));
        var merit = augmentedObjective(layout, current, multipliers, report.penalty);
        augmentedGradient(layout, current, multipliers, report.penalty, augmented_gradient);
        var inner_stalled = false;
        var inner_converged = false;
        for (0..options.max_inner_iterations) |_| {
            if (projectedNorm(layout, x, augmented_gradient) <= inner_tolerance) {
                inner_converged = true;
                break;
            }
            report.inner_iterations += 1;
            var accepted = false;
            for (0..2) |attempt| {
                if (attempt == 0) {
                    history.direction(layout, x, augmented_gradient, direction);
                    restrictDirection(layout, x, direction);
                } else {
                    history.clear();
                    for (direction, augmented_gradient, 0..) |*d, g, i| d.* = project(layout, i, x[i] - g) - x[i];
                }
                if (dot(augmented_gradient, direction) >= 0) continue;
                var step_size: f64 = 1;
                for (0..48) |_| {
                    for (candidate, x, direction, 0..) |*value, old, d, i| value.* = project(layout, i, old + step_size * d);
                    var slope: f64 = 0;
                    var movement: f64 = 0;
                    for (candidate, x, augmented_gradient) |value, old, g| {
                        const step = value - old;
                        slope += g * step;
                        movement = @max(movement, @abs(step));
                    }
                    if (slope >= 0 or movement == 0) break;
                    if (report.evaluations >= options.max_evaluations) {
                        measure(layout, x, current, multipliers, trial_gradient, &report);
                        report.status = .evaluation_limit;
                        return report;
                    }
                    if (evaluateValues(evaluator, candidate, &trial, &report.evaluations)) {
                        const next_merit = augmentedObjective(layout, trial, multipliers, report.penalty);
                        if (std.math.isFinite(next_merit) and next_merit <= merit + 1e-4 * slope and evaluateDerivatives(evaluator, candidate, &trial)) {
                            augmentedGradient(layout, trial, multipliers, report.penalty, trial_gradient);
                            history.append(layout, x, candidate, augmented_gradient, trial_gradient);
                            @memcpy(x, candidate);
                            std.mem.swap(Point, &current, &trial);
                            std.mem.swap([]f64, &augmented_gradient, &trial_gradient);
                            merit = next_merit;
                            accepted = true;
                            if (zeroMultipliers(layout, x, current, multipliers, trial_gradient, options, &report)) return report;
                            break;
                        }
                    }
                    step_size *= 0.5;
                }
                if (accepted) break;
            }
            if (!accepted) {
                inner_stalled = true;
                break;
            }
        }

        if (!inner_converged) inner_converged = projectedNorm(layout, x, augmented_gradient) <= inner_tolerance;
        if (!inner_converged) {
            measure(layout, x, current, multipliers, trial_gradient, &report);
            if (inner_stalled) {
                report.status = .stalled;
                return report;
            }
            continue;
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
        restart = true;
        measure(layout, x, current, multipliers, augmented_gradient, &report);
        if (converged(report, options)) {
            report.status = .converged;
            return report;
        }
        if (layout.constraint_count == 0 and inner_stalled) {
            report.status = .stalled;
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
        if (penalty_stalls >= 3) {
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

    fn init(allocator: std.mem.Allocator, n: usize, layout: Layout) Error!Point {
        return .{
            .gradient = try allocator.alloc(f64, n),
            .constraints = try allocator.alloc(f64, layout.constraint_count),
            .jacobian = try allocator.alloc(f64, layout.columns.len),
        };
    }
};

const History = struct {
    const capacity = 10;

    s: []f64,
    y: []f64,
    rho: [capacity]f64 = undefined,
    count: usize = 0,
    next: usize = 0,
    n: usize,

    fn init(allocator: std.mem.Allocator, n: usize) Error!History {
        return .{ .s = try allocator.alloc(f64, capacity * n), .y = try allocator.alloc(f64, capacity * n), .n = n };
    }

    fn clear(self: *History) void {
        self.count = 0;
        self.next = 0;
    }

    fn append(self: *History, layout: Layout, before: []const f64, after: []const f64, old_gradient: []const f64, gradient: []const f64) void {
        var sy: f64 = 0;
        var ss: f64 = 0;
        var yy: f64 = 0;
        for (before, after, old_gradient, gradient, 0..) |old, value, old_g, g, i| {
            const free_before = freeVariable(layout, i, old, old_g);
            const free_after = freeVariable(layout, i, value, g);
            if (free_before != free_after) {
                self.clear();
                return;
            }
            if (!free_after) continue;
            const s = value - old;
            const y = g - old_g;
            sy += s * y;
            ss += s * s;
            yy += y * y;
        }
        if (!std.math.isFinite(sy) or sy <= 1e-10 * @sqrt(ss) * @sqrt(yy) or yy == 0) return;
        const start = self.next * self.n;
        for (before, after, old_gradient, gradient, 0..) |old, value, old_g, g, i| {
            self.s[start + i] = value - old;
            self.y[start + i] = if (freeVariable(layout, i, value, g)) g - old_g else 0;
        }
        self.rho[self.next] = 1 / sy;
        self.next = (self.next + 1) % capacity;
        self.count = @min(self.count + 1, capacity);
    }

    fn direction(self: History, layout: Layout, x: []const f64, gradient: []const f64, out: []f64) void {
        for (gradient, x, out, 0..) |g, value, *q, i| q.* = if (freeVariable(layout, i, value, g)) g else 0;
        var alpha: [capacity]f64 = undefined;
        for (0..self.count) |age| {
            const index = (self.next + capacity - 1 - age) % capacity;
            const s = self.s[index * self.n ..][0..self.n];
            const y = self.y[index * self.n ..][0..self.n];
            alpha[age] = self.rho[index] * dot(s, out);
            subtractScaled(out, y, alpha[age]);
        }
        if (self.count > 0) {
            const index = (self.next + capacity - 1) % capacity;
            const y = self.y[index * self.n ..][0..self.n];
            const scale = std.math.clamp(1 / (self.rho[index] * dot(y, y)), 1e-12, 1e12);
            scaleValues(out, scale);
        }
        var age = self.count;
        while (age > 0) {
            age -= 1;
            const index = (self.next + capacity - 1 - age) % capacity;
            const s = self.s[index * self.n ..][0..self.n];
            const y = self.y[index * self.n ..][0..self.n];
            const beta = self.rho[index] * dot(y, out);
            addScaled(out, s, alpha[age] - beta);
        }
        scaleValues(out, -1);
    }
};

fn evaluateValues(evaluator: anytype, x: []const f64, point: *Point, evaluations: *usize) bool {
    evaluations.* += 1;
    const result: EvalError!void = evaluator.values(x, .{
        .objective = &point.objective,
        .constraints = point.constraints,
    });
    result catch return false;
    if (!std.math.isFinite(point.objective)) return false;
    for (point.constraints) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn evaluateDerivatives(evaluator: anytype, x: []const f64, point: *Point) bool {
    const result: EvalError!void = evaluator.derivatives(x, .{
        .gradient = point.gradient,
        .jacobian = point.jacobian,
    });
    result catch return false;
    for (point.gradient) |value| if (!std.math.isFinite(value)) return false;
    for (point.jacobian) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn augmentedObjective(layout: Layout, point: Point, multipliers: []const f64, penalty: f64) f64 {
    var objective = point.objective;
    for (point.constraints, multipliers, 0..) |c, lambda, row| {
        if (row < layout.equality_count) {
            objective += lambda * c + 0.5 * penalty * c * c;
        } else if (lambda - penalty * c > 0) {
            objective += -lambda * c + 0.5 * penalty * c * c;
        } else {
            objective -= 0.5 * lambda * (lambda / penalty);
        }
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

fn restrictDirection(layout: Layout, x: []const f64, direction: []f64) void {
    for (x, direction, 0..) |value, *d, i| {
        if (value <= layout.lower[i] and d.* < 0) d.* = 0;
        if (value >= layout.upper[i] and d.* > 0) d.* = 0;
    }
}

fn freeVariable(layout: Layout, index: usize, value: f64, gradient: f64) bool {
    if (layout.lower[index] == layout.upper[index]) return false;
    if (value <= layout.lower[index] and gradient >= 0) return false;
    if (value >= layout.upper[index] and gradient <= 0) return false;
    return true;
}

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += x * y;
    return sum;
}

const vector_width = std.simd.suggestVectorLength(f64) orelse 1;
const Vector = @Vector(vector_width, f64);

fn subtractScaled(out: []f64, input: []const f64, factor: f64) void {
    const factors: Vector = @splat(factor);
    var i: usize = 0;
    while (i + vector_width <= out.len) : (i += vector_width) {
        const values: Vector = out[i..][0..vector_width].*;
        const inputs: Vector = input[i..][0..vector_width].*;
        out[i..][0..vector_width].* = values - factors * inputs;
    }
    for (out[i..], input[i..]) |*value, v| value.* -= factor * v;
}

fn addScaled(out: []f64, input: []const f64, factor: f64) void {
    const factors: Vector = @splat(factor);
    var i: usize = 0;
    while (i + vector_width <= out.len) : (i += vector_width) {
        const values: Vector = out[i..][0..vector_width].*;
        const inputs: Vector = input[i..][0..vector_width].*;
        out[i..][0..vector_width].* = values + inputs * factors;
    }
    for (out[i..], input[i..]) |*value, v| value.* += v * factor;
}

fn scaleValues(out: []f64, factor: f64) void {
    const factors: Vector = @splat(factor);
    var i: usize = 0;
    while (i + vector_width <= out.len) : (i += vector_width) {
        const values: Vector = out[i..][0..vector_width].*;
        out[i..][0..vector_width].* = values * factors;
    }
    for (out[i..]) |*value| value.* *= factor;
}
