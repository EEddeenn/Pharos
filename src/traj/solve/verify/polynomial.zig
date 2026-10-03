const std = @import("std");
const candidate = @import("../candidate.zig");
pub const bound_accuracy: f64 = 1e-7;
const epsilon = std.math.floatEps(f64);

pub const Polynomial = struct {
    degree: usize = 0,
    coefficients: [11]f64 = @splat(0),
    roundoff: f64 = 0,

    pub fn constant(value: f64) Polynomial {
        var p: Polynomial = .{};
        p.coefficients[0] = value;
        return p;
    }

    pub fn magnitude(self: Polynomial) f64 {
        var sum: f64 = 0;
        for (self.coefficients[0 .. self.degree + 1]) |c| sum += @abs(c);
        return sum;
    }

    pub fn scaled(self: Polynomial, scale: f64) Polynomial {
        var result = self;
        for (result.coefficients[0 .. result.degree + 1]) |*c| c.* *= scale;
        result.roundoff = self.roundoff * @abs(scale) + 4 * epsilon * result.magnitude();
        return result;
    }

    pub fn add(a: Polynomial, b: Polynomial) Polynomial {
        var result: Polynomial = .{ .degree = @max(a.degree, b.degree), .roundoff = a.roundoff + b.roundoff + 4 * epsilon * (a.magnitude() + b.magnitude()) };
        for (result.coefficients[0 .. result.degree + 1], 0..) |*c, i| c.* = a.coefficients[i] + b.coefficients[i];
        return result;
    }

    pub fn derivative(self: Polynomial) Polynomial {
        var result: Polynomial = .{ .degree = self.degree -| 1, .roundoff = self.roundoff * @as(f64, @floatFromInt(self.degree)) };
        for (1..self.degree + 1) |i| result.coefficients[i - 1] = self.coefficients[i] * @as(f64, @floatFromInt(i));
        result.roundoff += 4 * epsilon * result.magnitude();
        return result;
    }

    pub fn square(self: Polynomial) Polynomial {
        const size = self.magnitude();
        var result: Polynomial = .{ .degree = self.degree * 2, .roundoff = 2 * size * self.roundoff + self.roundoff * self.roundoff + 32 * epsilon * size * size };
        for (0..self.degree + 1) |i| for (0..self.degree + 1) |j| {
            result.coefficients[i + j] += self.coefficients[i] * self.coefficients[j];
        };
        return result;
    }
};

pub const CellPolynomials = struct {
    position: [3]Polynomial,
    course: Polynomial,
    duration: f64,

    pub fn init(path: *const candidate.Path, index: usize) CellPolynomials {
        const cell = path.cells[index];
        const a = path.nodes[cell.left];
        const b = path.nodes[cell.right];
        const evaluator = path.evaluators[index];
        const h = evaluator.duration;
        var result: CellPolynomials = .{ .position = undefined, .course = .{ .degree = 3 }, .duration = h };
        for (&result.position, 0..) |*p, axis| {
            const delta = b.position[axis] - a.position[axis];
            const v0 = a.velocity[axis] * h;
            const v1 = b.velocity[axis] * h;
            const a0 = a.acceleration[axis] * h * h;
            const a1 = b.acceleration[axis] * h * h;
            p.* = .{ .degree = 5, .roundoff = 64 * epsilon * (@abs(delta) + @abs(v0) + @abs(v1) + @abs(a0) + @abs(a1)) };
            @memcpy(p.coefficients[0..6], &evaluator.position[axis]);
        }
        @memcpy(result.course.coefficients[0..4], &evaluator.course);
        result.course.roundoff = 32 * epsilon * (@abs(a.course) + @abs(b.course) + @abs(a.turn_rate * h) + @abs(b.turn_rate * h));
        return result;
    }
};

pub const Bounds = struct {
    lower: f64,
    upper: f64,
    resolved: bool,
};

const Search = struct {
    degree: usize,
    sampled_min: f64,
    sampled_max: f64,
    lower: f64 = std.math.inf(f64),
    upper: f64 = -std.math.inf(f64),
    nodes: usize = 0,
    resolved: bool = true,

    fn visit(self: *Search, coefficients: [11]f64, depth: usize) void {
        self.nodes += 1;
        var low = coefficients[0];
        var high = coefficients[0];
        for (coefficients[0 .. self.degree + 1]) |c| {
            if (!std.math.isFinite(c)) {
                self.lower = -std.math.inf(f64);
                self.upper = std.math.inf(f64);
                self.resolved = false;
                return;
            }
            low = @min(low, c);
            high = @max(high, c);
        }
        const halves = split(coefficients, self.degree, 0.5);
        self.sampled_min = @min(self.sampled_min, halves.left[self.degree]);
        self.sampled_max = @max(self.sampled_max, halves.left[self.degree]);
        if (low >= self.sampled_min - bound_accuracy and high <= self.sampled_max + bound_accuracy) {
            self.lower = @min(self.lower, low);
            self.upper = @max(self.upper, high);
            return;
        }
        if (depth >= 24 or self.nodes >= 8192) {
            self.lower = @min(self.lower, low);
            self.upper = @max(self.upper, high);
            self.resolved = false;
            return;
        }
        self.visit(halves.left, depth + 1);
        self.visit(halves.right, depth + 1);
    }
};

pub fn bounds(p: Polynomial, start: f64, end: f64) Bounds {
    var coefficients: [11]f64 = @splat(0);
    for (0..p.degree + 1) |k| for (0..k + 1) |i| {
        coefficients[k] += p.coefficients[i] * binomial(k, i) / binomial(p.degree, i);
    };
    if (start > 0) coefficients = split(coefficients, p.degree, start).right;
    if (end < 1 and start < 1) coefficients = split(coefficients, p.degree, (end - start) / (1 - start)).left;
    var search: Search = .{
        .degree = p.degree,
        .sampled_min = @min(coefficients[0], coefficients[p.degree]),
        .sampled_max = @max(coefficients[0], coefficients[p.degree]),
    };
    search.visit(coefficients, 0);
    const padding = p.roundoff + 128 * epsilon * p.magnitude();
    return .{ .lower = search.lower - padding, .upper = search.upper + padding, .resolved = search.resolved and std.math.isFinite(padding) };
}

const Split = struct { left: [11]f64, right: [11]f64 };

fn split(coefficients: [11]f64, degree: usize, u: f64) Split {
    var work = coefficients;
    var result: Split = .{ .left = coefficients, .right = coefficients };
    for (1..degree + 1) |level| {
        for (0..degree + 1 - level) |i| work[i] = work[i] * (1 - u) + work[i + 1] * u;
        result.left[level] = work[0];
        result.right[degree - level] = work[degree - level];
    }
    return result;
}

fn binomial(n: usize, k: usize) f64 {
    var result: f64 = 1;
    for (0..k) |i| result *= @as(f64, @floatFromInt(n - i)) / @as(f64, @floatFromInt(i + 1));
    return result;
}
