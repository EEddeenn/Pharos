//! The convex tier. With the events' times held, a rule of the tier's class is a row that is linear in the path's
//! unknowns, or a bound less the squared norm of a vector that is linear in them, and a target or an objective is
//! a sum of squares of such vectors. The rows and their derivatives at one point therefore state the whole
//! problem, and it is solved as what it is: a convex programme, by a primal-dual interior-point method whose
//! every step is one factor, along the path, of the symmetric matrix of the unknowns and the rows' multipliers.
//! What it makes least is the plan's own targets and objectives, or the path's jerk where the plan states none.
//! Where there is no path, a second programme (the least sum of what the rows are broken by) says so, and its
//! multipliers name the rows that cannot hold together.
//!
//! A rule that is linear only once the local frame is held (an altitude, a horizontal speed) is linearised where
//! the path is, and the programme is made again about its answer until the rows are what it said they would be,
//! and, where a target or an objective is such, until an answer moves nothing.
const std = @import("std");
const model = @import("../plan.zig").model;
const problem = @import("problem.zig");
const rules = @import("rules.zig");
const mesh_module = @import("mesh.zig");
const nlp = @import("nlp.zig");

pub const Error = std.mem.Allocator.Error;

pub const Outcome = enum {
    /// The path is the programme's optimum.
    optimal,
    /// No path of this mesh meets the rows: `conflict` names rows that cannot hold together.
    none,
    /// A row that no unknown moves is not met, which no path does on any mesh: `conflict` names it.
    unmet,
    /// The iteration ended without either.
    undecided,
    /// The rows could not be evaluated where the solve began.
    invalid,
    /// The work bound was reached.
    spent,
};

pub const Report = struct {
    outcome: Outcome = .undecided,
    iterations: usize = 0,
    work: usize = 0,
    /// The plan's own targets and objectives at the answer: nothing where it states none.
    objective: f64 = 0,
    /// Indices of the layout's constraints, where the outcome is `none` or `unmet`.
    conflict: []const usize = &.{},
};

/// A broken row counts as met below this: a hundredth of what the verifier passes.
const met = 1e-7;
/// An equality row holds through a multiplier that is drawn to it by this weight.
const equality_weight = 1e8;
/// Behind the least jerk, the acceleration breaks its ties: by this weight over the square of a section's
/// duration, so that the two are of one unit and the jerk decides wherever it can.
const tie = 1e-6;
/// The weight of the objective's curvature in the programme of least violation: it keeps that programme's answer
/// one point, near where the step began.
const hold = 0.1;
/// The most programmes of one mesh.
const most_passes = 8;
const none = std.math.maxInt(usize);

/// A symmetric matrix kept by rows, each from its first coupled unknown to its diagonal.
const Profile = struct {
    first: []usize,
    start: []usize,
    size: usize = 0,

    fn init(allocator: std.mem.Allocator, n: usize) Error!Profile {
        const first = try allocator.alloc(usize, n);
        for (first, 0..) |*f, i| f.* = i;
        return .{ .first = first, .start = try allocator.alloc(usize, n) };
    }

    fn widen(self: *Profile, places: []const usize) void {
        var lowest: usize = none;
        for (places) |place| lowest = @min(lowest, place);
        for (places) |place| {
            if (place != none) self.first[place] = @min(self.first[place], lowest);
        }
    }

    fn close(self: *Profile) void {
        self.size = 0;
        for (self.first, self.start, 0..) |first, *start, place| {
            start.* = self.size;
            self.size += place - first + 1;
        }
    }

    fn at(self: *const Profile, row: usize, column: usize) usize {
        return self.start[row] + column - self.first[row];
    }

    /// Adds `weight` times the square of a sparse row whose places are all different.
    fn add(self: *const Profile, entries: []f64, places: []const usize, values: []const f64, weight: f64) void {
        for (places, values, 0..) |a, va, index| {
            if (a == none or va == 0) continue;
            for (places[0 .. index + 1], values[0 .. index + 1]) |b, vb| {
                if (b != none) entries[self.at(@max(a, b), @min(a, b))] += weight * va * vb;
            }
        }
    }

    fn multiply(self: *const Profile, entries: []const f64, x: []const f64, out: []f64) void {
        @memset(out, 0);
        for (self.first, self.start, 0..) |first, start, i| {
            const row = entries[start..][0 .. i - first + 1];
            for (row[0 .. i - first], first..) |entry, j| {
                out[i] += entry * x[j];
                out[j] += entry * x[i];
            }
            out[i] += row[i - first] * x[i];
        }
    }

    /// The factors L D L' in place (L with ones on its diagonal, D in the diagonal's place). `positive` says of
    /// each row which sign its pivot has: the matrix is positive definite on the unknowns and negative definite on
    /// the multipliers, and such a matrix has these factors in any order. False where a pivot has the other sign
    /// to rounding.
    fn factorize(self: *const Profile, l: []f64, positive: []const bool) bool {
        for (self.first, self.start, 0..) |first, start, i| {
            const row = l[start..][0 .. i - first + 1];
            // First the row times D, entry by entry; then the pivot, and the row itself.
            for (first..i) |j| {
                const other = l[self.start[j]..][0 .. j - self.first[j] + 1];
                const from = @max(first, self.first[j]);
                row[j - first] -= dot(row[from - first .. j - first], other[from - self.first[j] .. j - self.first[j]]);
            }
            var pivot = row[i - first];
            for (row[0 .. i - first], first..) |*entry, j| {
                const scaled = entry.*;
                entry.* = scaled / l[self.at(j, j)];
                pivot -= scaled * entry.*;
            }
            if (!(if (positive[i]) pivot > 0 else pivot < 0)) return false;
            row[i - first] = pivot;
        }
        return true;
    }

    fn solve(self: *const Profile, l: []const f64, w: []f64) void {
        for (self.first, self.start, 0..) |first, start, i| w[i] -= dot(l[start..][0 .. i - first], w[first..i]);
        for (w, 0..) |*value, i| value.* /= l[self.at(i, i)];
        var i = w.len;
        while (i > 0) {
            i -= 1;
            const first = self.first[i];
            for (l[self.start[i]..][0 .. i - first], w[first..i]) |entry, *value| value.* -= entry * w[i];
        }
    }
};

const RowKind = enum { skip, equality, inequality };

/// A row as the programme holds it: an inequality row once; an equality row, in the programme of least violation,
/// twice with opposite signs.
const Instance = struct { row: usize, sign: f64 };

/// `unbounded` is `optimum` without the inequality rows: where its answer meets them, it is the optimum.
const Phase = enum { unbounded, optimum, least_violation };
const Ended = enum { converged, stalled };

const Solver = struct {
    layout: *const problem.Layout,
    /// The objective's matrix over the unknowns, and the step's matrix over the unknowns and the multipliers.
    objective: Profile,
    system: Profile,
    /// Of every entry of the layout's rows: its unknown's place in the objective's matrix and its slot in the
    /// step's. Of every unknown its slot; of every row the slot of its multiplier (an equality row has the next
    /// one as well); of every slot whether it is an unknown's.
    row_places: []const usize,
    row_slots: []const usize,
    slots: []const usize,
    multipliers: []const usize,
    positive: []const bool,
    kinds: []const RowKind,
    // The model about the point of evaluation.
    values: []const f64,
    jacobian: []const f64,
    curved: []const f64,
    hessian: []f64,
    gradient: []f64,
    // The iterate: the step from the point of evaluation, the equality rows' multipliers, and for every instance
    // its slack and multiplier (and, where it may be broken, what it is broken by and that amount's multiplier).
    d: []f64,
    y: []f64,
    s: []f64,
    z: []f64,
    t: []f64,
    w: []f64,
    instances: []Instance,
    count: usize = 0,
    // Scratch.
    value: []f64,
    grad: []f64,
    matrix: []f64,
    residual: []f64,
    rhs: []f64,
    step: []f64,
    theta: []f64,
    push: []f64,
    iterations: usize = 0,

    const Slice = struct { places: []const usize, slots: []const usize, a: usize, b: usize };

    fn slice(self: *const Solver, row: usize) Slice {
        const a = self.layout.row_offsets[row];
        const b = self.layout.row_offsets[row + 1];
        return .{ .places = self.row_places[a..b], .slots = self.row_slots[a..b], .a = a, .b = b };
    }

    /// Every row's value and gradient at the step `d`: exact, the rows being linear or a bound less a squared norm.
    fn evaluate(self: *Solver) void {
        for (self.kinds, 0..) |kind, row| {
            if (kind == .skip) continue;
            const at = self.slice(row);
            const grad = self.grad[at.a..at.b];
            @memcpy(grad, self.jacobian[at.a..at.b]);
            var value = self.values[row] + along(at.places, grad, self.d);
            var offset = self.layout.curved_offsets[row];
            while (offset < self.layout.curved_offsets[row + 1]) : (offset += at.places.len) {
                const bend = self.curved[offset..][0..at.places.len];
                const c = along(at.places, bend, self.d);
                value -= 0.5 * c * c;
                for (grad, bend) |*g, entry| g.* -= c * entry;
            }
            self.value[row] = value;
        }
    }

    /// The interior-point iteration from a step of zero. In the phase `optimum` the objective is `weight` times
    /// the model's, the inequality rows hold through slacks and the equality rows through a proximal multiplier.
    /// In the phase `least_violation` every row may be broken, at the cost of what it is broken by, and the
    /// objective is that cost (with `weight` times the model's curvature, so that the minimum is one point).
    fn interior(self: *Solver, phase: Phase, weight: f64, max_iterations: usize) Ended {
        const elastic = phase == .least_violation;
        self.count = 0;
        for (self.kinds, 0..) |kind, row| switch (kind) {
            .skip => {},
            .inequality => if (phase != .unbounded) self.append(row, 1),
            .equality => if (elastic) {
                self.append(row, 1);
                self.append(row, -1);
            },
        };
        const instances = self.instances[0..self.count];
        @memset(self.d, 0);
        @memset(self.y, 0);
        self.evaluate();
        for (instances, 0..) |instance, k| {
            const v = instance.sign * self.value[instance.row];
            if (elastic) {
                self.s[k] = 1 + @max(v, 0);
                self.t[k] = self.s[k] - v;
                self.z[k] = 0.5;
                self.w[k] = 0.5;
            } else {
                self.s[k] = @max(v, 1e-2 * (1 + @abs(v)));
                self.z[k] = @min(1e4, 1 / self.s[k]);
            }
        }
        var mu = self.gap(elastic);
        var sigma: f64 = 0.5;
        var raise: f64 = 0;
        var slow: usize = 0;
        for (0..max_iterations) |_| {
            self.iterations += 1;
            // Minus the residual of stationarity: the rows' pull less the objective's gradient. `pull` is the size
            // of what cancels in it: the tests of the end are relative to that.
            self.objective.multiply(self.hessian, self.d, self.residual);
            for (self.residual, self.gradient) |*r, g| r.* = -weight * (r.* + (if (elastic) 0 else g));
            var pull: f64 = 1;
            if (!elastic) for (self.kinds, 0..) |kind, row| {
                if (kind != .equality) continue;
                const at = self.slice(row);
                for (at.places, self.jacobian[at.a..at.b]) |place, entry| self.residual[place] += self.y[row] * entry;
            };
            for (instances, 0..) |instance, k| {
                const at = self.slice(instance.row);
                for (at.places, self.grad[at.a..at.b]) |place, entry| {
                    self.residual[place] += instance.sign * self.z[k] * entry;
                    pull = @max(pull, @abs(self.z[k] * entry));
                }
            }
            var stationarity: f64 = 0;
            for (self.residual) |r| stationarity = @max(stationarity, @abs(r));
            stationarity /= pull;

            // The matrix of the step: the objective's (and the curvature of the rows that curve, each by its
            // multiplier) over the unknowns; each row's gradient across from its multiplier; and on a multiplier's
            // diagonal minus its slack over itself, which goes to zero as the row comes to hold.
            const size = self.system.size;
            @memset(self.matrix[0..size], 0);
            @memset(self.rhs, 0);
            for (self.objective.first, self.objective.start, 0..) |first, start, i| {
                for (self.hessian[start..][0 .. i - first + 1], first..) |h, j| self.matrix[self.system.at(self.slots[i], self.slots[j])] = weight * h;
                self.matrix[self.system.at(self.slots[i], self.slots[i])] += raise;
                self.rhs[self.slots[i]] = self.residual[i];
            }
            for (self.positive, 0..) |positive, slot| {
                if (!positive) self.matrix[self.system.at(slot, slot)] = -1;
            }
            var primal: f64 = 0;
            if (!elastic) for (self.kinds, 0..) |kind, row| {
                if (kind != .equality) continue;
                const at = self.slice(row);
                const slot = self.multipliers[row];
                primal = @max(primal, @abs(self.value[row]));
                for (at.slots, self.jacobian[at.a..at.b]) |column, entry| self.matrix[self.system.at(slot, column)] = entry;
                self.matrix[self.system.at(slot, slot)] = -1.0 / equality_weight - raise;
                self.rhs[slot] = -self.value[row];
            };
            const target = sigma * mu;
            for (instances, 0..) |instance, k| {
                const at = self.slice(instance.row);
                const grad = self.grad[at.a..at.b];
                const slot = self.multipliers[instance.row] + @intFromBool(instance.sign < 0);
                const v = instance.sign * self.value[instance.row];
                const centre = target - self.s[k] * self.z[k];
                // `push` is what the multiplier's row of the system asks for; `theta` the row's weight in the step.
                if (elastic) {
                    const short = v + self.t[k] - self.s[k];
                    const centre_t = target - self.t[k] * self.w[k];
                    const dual = self.z[k] + self.w[k] - 1;
                    self.theta[k] = 1 / (self.t[k] / self.w[k] + self.s[k] / self.z[k]);
                    self.push[k] = -short - (centre_t + self.t[k] * dual) / self.w[k] + centre / self.z[k];
                    primal = @max(primal, @abs(short));
                    stationarity = @max(stationarity, @abs(dual));
                } else {
                    const short = v - self.s[k];
                    self.theta[k] = self.z[k] / self.s[k];
                    self.push[k] = centre / self.z[k] - short;
                    primal = @max(primal, @abs(short));
                }
                for (at.slots, grad) |column, entry| self.matrix[self.system.at(slot, column)] = instance.sign * entry;
                // A slack at zero would leave a zero on the diagonal: the factors need a little there.
                self.matrix[self.system.at(slot, slot)] = -@max(1 / self.theta[k], 1e-11) - raise;
                self.rhs[slot] = self.push[k];
                var offset = self.layout.curved_offsets[instance.row];
                while (offset < self.layout.curved_offsets[instance.row + 1]) : (offset += at.places.len) self.system.add(self.matrix, at.slots, self.curved[offset..][0..at.places.len], self.z[k]);
            }
            // The gap is relative to the same size. At a gap of 1e-8 a row that holds is 1e-8 of its unit inside
            // its bound, which no check can tell from on it; far below that the factors lose their footing.
            if (stationarity <= 1e-9 and primal <= 1e-9 and mu <= 1e-8 * pull) return .converged;

            if (!self.system.factorize(self.matrix[0..size], self.positive)) {
                // A pivot of the wrong sign, to rounding: the matrix is made again with its diagonal raised.
                raise = if (raise == 0) 1e-12 else raise * 100;
                if (raise > 1e-4) return .stalled;
                continue;
            }
            self.system.solve(self.matrix[0..size], self.rhs);
            for (self.step, self.slots) |*value, slot| {
                value.* = self.rhs[slot];
                if (!std.math.isFinite(value.*)) return .stalled;
            }
            var alpha: f64 = 1;
            for (instances, 0..) |instance, k| {
                const change = self.changes(instance, k, target, elastic);
                alpha = @min(alpha, @min(room(self.s[k], change.s), room(self.z[k], change.z)));
                if (elastic) alpha = @min(alpha, @min(room(self.t[k], change.t), room(self.w[k], change.w)));
            }
            for (instances, 0..) |instance, k| {
                const change = self.changes(instance, k, target, elastic);
                self.s[k] += alpha * change.s;
                self.z[k] += alpha * change.z;
                if (elastic) {
                    self.t[k] += alpha * change.t;
                    self.w[k] += alpha * change.w;
                }
            }
            if (!elastic) for (self.kinds, self.multipliers, self.y) |kind, slot, *y| {
                if (kind == .equality) y.* -= alpha * self.rhs[slot];
            };
            for (self.d, self.step) |*value, change| value.* += alpha * change;
            self.evaluate();
            // A row that curves may leave more room than its slack was moved to: the slack takes it.
            for (instances, 0..) |instance, k| {
                const v = instance.sign * self.value[instance.row] + (if (elastic) self.t[k] else 0);
                if (v > self.s[k]) self.s[k] = v;
            }
            mu = self.gap(elastic);
            sigma = if (alpha >= 0.9) 0.1 else if (alpha >= 0.5) 0.3 else 0.6;
            // Four steps running that are a hundredth of a step: the rows cannot be met, or the iteration is lost.
            slow = if (alpha < 1e-2) slow + 1 else 0;
            if (slow == 4) return .stalled;
        }
        return .stalled;
    }

    /// `interior` within what the work bound leaves of `report`'s: each iteration is a factor of the step's matrix.
    fn within(self: *Solver, report: *Report, phase: Phase, weight: f64, most: usize, max_work: usize) Ended {
        const mark = self.iterations;
        const ended = self.interior(phase, weight, @min(most, (max_work -| report.work) / nlp.factor_work));
        report.work += nlp.factor_work * (self.iterations - mark);
        return ended;
    }

    const Changes = struct { s: f64, z: f64, t: f64 = 0, w: f64 = 0 };

    /// What the step makes of one instance's slack and multipliers. The multiplier's change is the system's own
    /// answer (its slot of the solution, with the other sign): made again from the unknowns' step it would be a
    /// small difference times a large weight.
    fn changes(self: *const Solver, instance: Instance, k: usize, target: f64, elastic: bool) Changes {
        const dz = -self.rhs[self.multipliers[instance.row] + @intFromBool(instance.sign < 0)];
        const ds = (target - self.s[k] * self.z[k] - self.s[k] * dz) / self.z[k];
        if (!elastic) return .{ .s = ds, .z = dz };
        const dw = -dz - (self.z[k] + self.w[k] - 1);
        return .{ .s = ds, .z = dz, .w = dw, .t = (target - self.t[k] * self.w[k] - self.t[k] * dw) / self.w[k] };
    }

    fn append(self: *Solver, row: usize, sign: f64) void {
        self.instances[self.count] = .{ .row = row, .sign = sign };
        self.count += 1;
    }

    fn gap(self: *const Solver, elastic: bool) f64 {
        if (self.count == 0) return 0;
        var sum: f64 = 0;
        for (self.s[0..self.count], self.z[0..self.count]) |s, z| sum += s * z;
        if (elastic) for (self.t[0..self.count], self.w[0..self.count]) |t, w| {
            sum += t * w;
        };
        return sum / @as(f64, @floatFromInt(if (elastic) 2 * self.count else self.count));
    }
};

/// How far of a step a positive quantity may go and keep a two-hundredth of itself.
fn room(value: f64, change: f64) f64 {
    return if (change < 0) @min(1, -0.995 * value / change) else 1;
}

/// The convex programme of a layout about `x`, solved, and `x` moved to its answer: the layout of a plan the tier
/// takes (`rules.shape`). `shape.frame` says that some row or soft term is what it is only where the path is: the
/// programme is then made again about its answer.
pub fn solve(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, layout: *const problem.Layout, workspace: *problem.Workspace, x: []f64, shape: rules.Shape, max_work: usize) Error!Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const prepared = layout.rules;
    const n = layout.order.len;
    const rows = layout.constraints.len;
    const place = try memory.alloc(usize, x.len);
    @memset(place, none);
    for (layout.order, 0..) |column, index| place[column] = index;
    const row_places = try memory.alloc(usize, layout.columns.len);
    for (row_places, layout.columns) |*out, column| out.* = place[column];
    const soft_places = try memory.alloc(usize, layout.soft_columns.len);
    for (soft_places, layout.soft_columns) |*out, column| out.* = place[column];
    // A bound that cannot bind is no row. Neither is a row that holds no unknown: it is a number, looked at where
    // it is read.
    const vacuous = try memory.alloc(bool, rows);
    const kinds = try memory.alloc(RowKind, rows);
    for (kinds, vacuous, layout.constraints, 0..) |*kind, *is, term, row| {
        is.* = rules.kindOf(prepared, prepared.checks[term.check().?]) == .vacuous;
        const empty = layout.row_offsets[row] == layout.row_offsets[row + 1];
        kind.* = if (is.* or empty) .skip else if (row < layout.equality_count) .equality else .inequality;
    }

    // The objective's matrix, over the unknowns in the order of the path.
    const mesh = &layout.mesh;
    var objective = try Profile.init(memory, n);
    for (mesh.cells) |cell| for (0..3) |axis| {
        var places: [6]usize = undefined;
        for (&places, cellColumns(mesh, cell, axis)) |*out, column| out.* = place[column];
        objective.widen(&places);
    };
    for (0..layout.objectives.len) |term| objective.widen(soft_places[layout.soft_offsets[term]..layout.soft_offsets[term + 1]]);
    objective.close();

    // The step's matrix: the unknowns in the same order, and each row's multiplier after the last of its unknowns
    // (an equality row's two: the second is for the programme of least violation).
    const last = try memory.alloc(usize, rows);
    const after = try memory.alloc(usize, n + 1);
    @memset(after, 0);
    for (0..rows) |row| {
        if (kinds[row] == .skip) continue;
        var highest: usize = 0;
        for (row_places[layout.row_offsets[row]..layout.row_offsets[row + 1]]) |p| highest = @max(highest, p);
        last[row] = highest;
        after[highest] += if (kinds[row] == .equality) 2 else 1;
    }
    const slots = try memory.alloc(usize, n);
    var total: usize = 0;
    for (slots, after[0..n]) |*slot, count| {
        slot.* = total;
        total += 1 + count;
    }
    const multipliers = try memory.alloc(usize, rows);
    @memset(after, 0);
    for (0..rows) |row| {
        if (kinds[row] == .skip) continue;
        multipliers[row] = slots[last[row]] + 1 + after[last[row]];
        after[last[row]] += if (kinds[row] == .equality) 2 else 1;
    }
    const positive = try memory.alloc(bool, total);
    @memset(positive, false);
    for (slots) |slot| positive[slot] = true;
    const row_slots = try memory.alloc(usize, layout.columns.len);
    for (row_slots, row_places) |*out, p| out.* = slots[p];
    var system = try Profile.init(memory, total);
    for (objective.first, 0..) |first, i| system.first[slots[i]] = slots[first];
    for (0..rows) |row| {
        if (kinds[row] == .skip) continue;
        const columns = row_slots[layout.row_offsets[row]..layout.row_offsets[row + 1]];
        // A row that curves couples its unknowns with one another; every row couples them with its multiplier.
        if (layout.curved_offsets[row] != layout.curved_offsets[row + 1]) system.widen(columns);
        var lowest: usize = none;
        for (columns) |slot| lowest = @min(lowest, slot);
        system.first[multipliers[row]] = lowest;
        if (kinds[row] == .equality) system.first[multipliers[row] + 1] = lowest;
    }
    system.close();

    const values = try memory.alloc(f64, rows);
    const jacobian = try memory.alloc(f64, layout.columns.len);
    const curved = try memory.alloc(f64, layout.curved_offsets[rows]);
    // The evaluator's objective is the layout's soft terms: each a square, with its row of the Gauss-Newton matrix.
    var value: f64 = 0;
    const gradient = try memory.alloc(f64, x.len);
    const soft = try memory.alloc(f64, layout.soft_columns.len);
    var solver: Solver = .{
        .layout = layout,
        .objective = objective,
        .system = system,
        .row_places = row_places,
        .row_slots = row_slots,
        .slots = slots,
        .multipliers = multipliers,
        .positive = positive,
        .kinds = kinds,
        .values = values,
        .jacobian = jacobian,
        .curved = curved,
        .hessian = try memory.alloc(f64, objective.size),
        .gradient = try memory.alloc(f64, n),
        .d = try memory.alloc(f64, n),
        .y = try memory.alloc(f64, rows),
        .s = try memory.alloc(f64, 2 * rows),
        .z = try memory.alloc(f64, 2 * rows),
        .t = try memory.alloc(f64, 2 * rows),
        .w = try memory.alloc(f64, 2 * rows),
        .instances = try memory.alloc(Instance, 2 * rows),
        .value = try memory.alloc(f64, rows),
        .grad = try memory.alloc(f64, layout.columns.len),
        .matrix = try memory.alloc(f64, system.size),
        .residual = try memory.alloc(f64, n),
        .rhs = try memory.alloc(f64, total),
        .step = try memory.alloc(f64, n),
        .theta = try memory.alloc(f64, 2 * rows),
        .push = try memory.alloc(f64, 2 * rows),
    };

    var report: Report = .{};
    // The most a row was broken by at the least, where the pass before found no step that meets the rows.
    var doubt: ?f64 = null;
    var confirmed = false;
    // How far the last answer moved the path, in the unknowns' own scaled units.
    var moved: f64 = std.math.inf(f64);
    for (0..most_passes) |pass| {
        // The work bound is held where it can be passed: before each evaluation, and at each iteration.
        if (report.work + 1 > max_work) {
            report.outcome = .spent;
            break;
        }
        report.work += 1;
        workspace.values(x, .{ .objective = &value, .constraints = values }) catch {
            report.outcome = .invalid;
            return report;
        };
        // A row that holds no unknown is a number: it is met or it is not.
        if (pass == 0) for (vacuous, values, 0..) |is, number, row| {
            if (is or layout.row_offsets[row] != layout.row_offsets[row + 1]) continue;
            // The plan's own number: without the margin the tier may hold the row by, which is no rule's.
            const plain = number + layout.constraints[row].margin;
            if (if (row < layout.equality_count) @abs(plain) > met else plain < -met) {
                report.outcome = .unmet;
                report.conflict = try result_allocator.dupe(usize, &.{row});
                return report;
            }
        };
        if (pass > 0) {
            // The rows where the path now is, against what the programme said they would be: where they are the
            // same, its answer is the plan's (the objective being the same quadratic wherever it is read, or the
            // last answer having moved nothing). A limit the programme left well short of being reached need only
            // still hold.
            var off: f64 = 0;
            for (kinds, values, solver.value) |kind, number, foretold| switch (kind) {
                .skip => {},
                .equality => off = @max(off, @abs(number - foretold)),
                .inequality => off = @max(off, if (foretold > 1e-3) @max(0, -number) else @abs(number - foretold)),
            };
            if (report.outcome == .optimal and off <= met and (!shape.soft or moved <= 1e-6)) {
                confirmed = true;
                break;
            }
        }
        if (report.work + nlp.derivative_work > max_work) {
            report.outcome = .spent;
            break;
        }
        report.work += nlp.derivative_work;
        workspace.derivatives(x, .{ .gradient = gradient, .jacobian = jacobian, .soft = soft, .curved = curved }) catch {
            report.outcome = .invalid;
            return report;
        };
        // A row no unknown moves (the unknowns it lists have no part in it) is a number as well.
        if (pass == 0) for (kinds, values, 0..) |*kind, number, row| {
            if (kind.* == .skip) continue;
            const moves = for (jacobian[layout.row_offsets[row]..layout.row_offsets[row + 1]]) |entry| {
                if (entry != 0) break true;
            } else for (curved[layout.curved_offsets[row]..layout.curved_offsets[row + 1]]) |entry| {
                if (entry != 0) break true;
            } else false;
            if (moves) continue;
            // The plan's own number: without the margin the tier may hold the row by, which is no rule's.
            const plain = number + layout.constraints[row].margin;
            if (if (kind.* == .equality) @abs(plain) > met else plain < -met) {
                report.outcome = .unmet;
                report.conflict = try result_allocator.dupe(usize, &.{row});
                return report;
            }
            kind.* = .skip;
        };

        // The objective, about where the path now is: the plan's own targets and objectives, or the path's
        // smoothness where it states none.
        @memset(solver.hessian, 0);
        for (solver.gradient, layout.order) |*g, column| g.* = gradient[column];
        for (0..layout.objectives.len) |term| {
            const a = layout.soft_offsets[term];
            const b = layout.soft_offsets[term + 1];
            objective.add(solver.hessian, soft_places[a..b], soft[a..b], 1);
        }
        if (own(prepared.plan, mesh, x, place, &objective, solver.hessian, solver.gradient) == null) _ = smoothness(mesh, x, place, &objective, solver.hessian, solver.gradient, .all, 3, 1);
        var size: f64 = 0;
        for (0..n) |i| size = @max(size, solver.hessian[objective.at(i, i)]);
        for (solver.gradient) |g| size = @max(size, @abs(g));
        if (!(size > 0)) size = 1;
        const weight: f64 = 1 / size;
        // What no rule and no part of the objective holds stays where it is.
        for (0..n) |i| {
            const entry = &solver.hessian[objective.at(i, i)];
            entry.* = entry.* * (1 + 1e-10) + 1e-14 * size;
        }

        var ended: Ended = .stalled;
        if (doubt == null) {
            // Most limits are not reached: the optimum without the inequality rows is tried first (a step or two).
            ended = solver.within(&report, .unbounded, weight, 12, max_work);
            if (ended == .converged) for (kinds, solver.value) |kind, number| {
                if (kind == .inequality and !(number >= 0)) ended = .stalled;
            };
            if (ended != .converged) ended = solver.within(&report, .optimum, weight, 80, max_work);
        }
        if (ended == .converged) {
            moved = 0;
            for (layout.order, solver.d) |column, change| {
                x[column] += change;
                moved = @max(moved, @abs(change));
            }
            report.outcome = .optimal;
            // Rows and soft terms that are exact where they were read are exact where the path now is.
            if (!shape.frame) {
                confirmed = true;
                break;
            }
        } else {
            // Is there a path at all? The least sum of what the rows are broken by, with a trace of the objective
            // that keeps the step near where it began. The trace costs: so the programme is made again from its
            // answer, and "no path" is said when that changes nothing. Its multipliers are the rows that push.
            const again = solver.within(&report, .least_violation, hold * weight, 120, max_work);
            var worst: f64 = 0;
            for (solver.instances[0..solver.count]) |instance| worst = @max(worst, -instance.sign * solver.value[instance.row]);
            report.outcome = if (report.work + nlp.factor_work > max_work) .spent else .undecided;
            moved = std.math.inf(f64);
            if (again != .converged) break;
            for (layout.order, solver.d) |column, change| x[column] += change;
            if (worst > met) {
                if (doubt) |before| if (worst >= 0.999 * before) {
                    var conflict: std.ArrayList(usize) = .empty;
                    for (solver.instances[0..solver.count], solver.z[0..solver.count]) |instance, z| {
                        if (z > 1e-3 and (conflict.items.len == 0 or conflict.items[conflict.items.len - 1] != instance.row)) try conflict.append(result_allocator, instance.row);
                    }
                    report.conflict = conflict.items;
                    report.outcome = .none;
                    report.iterations = solver.iterations;
                    return report;
                };
                doubt = worst;
            } else doubt = null;
        }
        if (report.work >= max_work) {
            report.outcome = .spent;
            break;
        }
    }
    if (report.outcome == .optimal and !confirmed) report.outcome = .undecided;
    report.iterations = solver.iterations;
    // What the plan's own targets and objectives come to where the path now is (the step's matrix is scratch here).
    if (own(prepared.plan, mesh, x, place, &objective, solver.hessian, solver.gradient)) |smooth| {
        report.work += 1;
        workspace.values(x, .{ .objective = &value, .constraints = values }) catch return report;
        report.objective = value + smooth;
    }
    return report;
}

/// A plan's own words on its smoothness (`rules.smoothed`), each added to the objective as `smoothness`
/// integrates it, by its weight over the square of its scale, and over its scope's time where it is a mean: what
/// they come to. Null where the plan states no target and no objective at all.
fn own(plan: *const model.Plan, mesh: *const mesh_module.Mesh, x: []const f64, place: []const usize, profile: *const Profile, hessian: []f64, gradient: []f64) ?f64 {
    var sum: ?f64 = null;
    for (plan.rules) |rule| {
        if (rule.kind() == .hard) continue;
        if (sum == null) sum = 0;
        const order = rules.smoothed(rule) orelse continue;
        var factor = rule.weight / (rule.scale * rule.scale);
        if (rule.definition.quantity.comparison.objective == .mean_square) factor /= switch (rule.scope) {
            .all => lasts(mesh, x, 0, mesh.sections.len),
            .section => |index| lasts(mesh, x, index, index + 1),
            .between => |ends| lasts(mesh, x, ends[0], ends[1]),
            .time_range => |range| range[1] - range[0],
            .event, .time => unreachable,
        };
        sum.? += smoothness(mesh, x, place, profile, hessian, gradient, rule.scope, order, factor);
    }
    return sum;
}

/// The time the sections from one to another take.
fn lasts(mesh: *const mesh_module.Mesh, x: []const f64, from: usize, to: usize) f64 {
    var sum: f64 = 0;
    for (mesh.durations[from..to]) |column| sum += x[column] * mesh_module.time_scale;
    return sum;
}

/// The columns of one axis of a cell's two nodes: place, velocity and acceleration of each.
fn cellColumns(mesh: *const mesh_module.Mesh, cell: mesh_module.Cell, axis: usize) [6]usize {
    const a = mesh.nodes[cell.left].variables;
    const b = mesh.nodes[cell.right].variables;
    return .{ a[axis], a[axis + 3], a[axis + 6], b[axis], b[axis + 3], b[axis + 6] };
}

/// `factor` times the integral, over what a scope covers, of the squared jerk (`order` 3) or acceleration (2),
/// added to the objective's matrix and gradient about `x`; what it comes to at `x` is returned. Behind the jerk,
/// the acceleration by a small weight (`tie`) breaks its ties, and is no part of what is returned. Each is a sum
/// over the cells of exact integrals: five Gauss points integrate the square of a polynomial of degree four exactly.
fn smoothness(mesh: *const mesh_module.Mesh, x: []const f64, place: []const usize, profile: *const Profile, hessian: []f64, gradient: []f64, scope: model.Scope, order: usize, factor: f64) f64 {
    const nodes = [_]f64{ 0.5, 0.5 - 0.5 * 0.5384693101056831, 0.5 + 0.5 * 0.5384693101056831, 0.5 - 0.5 * 0.9061798459386640, 0.5 + 0.5 * 0.9061798459386640 };
    const weights = [_]f64{ 0.5 * 0.5688888888888889, 0.5 * 0.4786286704993665, 0.5 * 0.4786286704993665, 0.5 * 0.2369268850561891, 0.5 * 0.2369268850561891 };
    var sum: f64 = 0;
    for (mesh.cells) |cell| {
        const span = x[mesh.durations[cell.section]] * mesh_module.time_scale;
        const h = span * (cell.end - cell.start);
        // The part of the cell that the scope covers.
        const part: [2]f64 = switch (scope) {
            .all => .{ 0, 1 },
            .section => |index| if (cell.section == index) .{ 0, 1 } else continue,
            .between => |ends| if (cell.section >= ends[0] and cell.section < ends[1]) .{ 0, 1 } else continue,
            .time_range => |range| blk: {
                const from = lasts(mesh, x, 0, cell.section) + span * cell.start;
                const covered = [2]f64{ @max(0, (range[0] - from) / h), @min(1, (range[1] - from) / h) };
                if (!(covered[1] > covered[0])) continue;
                break :blk covered;
            },
            .event, .time => unreachable,
        };
        for ([_]usize{ 3, 2 }) |derivative| {
            const share: f64 = if (derivative == order) 1 else if (order == 3) tie / (span * span) else continue;
            for (nodes, weights) |s, quadrature| {
                const row = derivativeRow(derivative, h, part[0] + (part[1] - part[0]) * s);
                for (0..3) |axis| {
                    const columns = cellColumns(mesh, cell, axis);
                    var places: [6]usize = undefined;
                    var entries: [6]f64 = undefined;
                    var value: f64 = 0;
                    for (columns, row, 0..) |column, entry, k| {
                        places[k] = place[column];
                        entries[k] = entry * mesh.scales[axis + 3 * (k % 3)];
                        value += entries[k] * x[column];
                    }
                    // Where the two nodes share an unknown (a stay), it is one place in the row.
                    for (0..3) |k| if (columns[k] == columns[k + 3]) {
                        entries[k] += entries[k + 3];
                        places[k + 3] = none;
                    };
                    const weight = factor * share * quadrature * h * (part[1] - part[0]);
                    // The square's own second derivative and slope, as the layout's soft terms give theirs.
                    profile.add(hessian, &places, &entries, 2 * weight);
                    for (places, entries) |p, entry| {
                        if (p != none) gradient[p] += 2 * weight * entry * value;
                    }
                    if (derivative == order) sum += weight * value * value;
                }
            }
        }
    }
    return sum;
}

/// The row that takes (p0, v0, a0, p1, v1, a1) of a quintic piece of duration h to its second or third derivative
/// at the fraction s of the piece.
fn derivativeRow(order: usize, h: f64, s: f64) [6]f64 {
    const s2 = s * s;
    const s3 = s2 * s;
    const basis: [5]f64 = if (order == 2)
        .{ 60 * s - 180 * s2 + 120 * s3, -36 * s + 96 * s2 - 60 * s3, 1 - 9 * s + 18 * s2 - 10 * s3, -24 * s + 84 * s2 - 60 * s3, 3 * s - 12 * s2 + 10 * s3 }
    else
        .{ 60 - 360 * s + 360 * s2, -36 + 192 * s - 180 * s2, -9 + 36 * s - 30 * s2, -24 + 168 * s - 180 * s2, 3 - 24 * s + 30 * s2 };
    const k = 1 / std.math.pow(f64, h, @floatFromInt(order));
    return .{ -basis[0] * k, basis[1] * h * k, basis[2] * h * h * k, basis[0] * k, basis[3] * h * k, basis[4] * h * h * k };
}

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |p, q| sum += p * q;
    return sum;
}

/// A sparse row along a vector over the places.
fn along(places: []const usize, values: []const f64, vector: []const f64) f64 {
    var sum: f64 = 0;
    for (places, values) |place, value| {
        if (place != none) sum += value * vector[place];
    }
    return sum;
}
