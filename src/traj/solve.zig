const std = @import("std");
const shared = @import("shared");
const model = @import("plan.zig").model;
const mesh = @import("solve/mesh.zig");
const rules = @import("solve/rules.zig");
const problem = @import("solve/problem.zig");
const candidate = @import("solve/candidate.zig");
const nlp = @import("solve/nlp.zig");
const verify = @import("solve/verify.zig");

/// The optimiser holds a range at its own points only and leaves the path on the range's edge there, so that it
/// overruns between them. A rule's margin is how far inside its range the optimiser keeps the path at those points,
/// in the rule's normalised measure. A range the verifier finds overrun gets `margin_gain` times the overrun more
/// of it for the next pass: twice, because the path moves when it is held in, and may overrun elsewhere by more
/// than it did. A margin the optimiser then cannot meet is cut to `margin_relax` of it: to a quarter, because the
/// passes are six, and a margin that is too wide has to come down in one or two of them.
const margin_gain = 2;
const margin_relax = 0.25;

pub const RuleReport = verify.RuleReport;
pub const SampleState = candidate.SampleState;
pub const Status = enum { converged, iterationLimit, workLimit, infeasible, numericalFailure, verificationFailed };
pub const Report = struct {
    status: Status,
    feasible: bool,
    verified: bool,
    /// Whether the soft rules were at their best when the solve stopped: true where the plan has none.
    settled: bool,
    iterations: usize,
    /// What the solve spent, in the unit of `Options.max_work`.
    work: usize,
    objective: f64,
    max_violation: f64,
    stationarity: f64,
};
pub const Result = struct {
    plan: model.Plan,
    path: candidate.Path,
    trajectory: shared.trajectory.Trajectory,
    report: Report,
    rule_reports: []const RuleReport,
};

pub const Options = struct {
    /// The most work the solve may spend, over all its mesh passes. A unit is one evaluation of the plan's rules
    /// on one cell of the mesh: a pass costs its cells times what its optimiser counts, which is 1 for an
    /// evaluation of the values, `nlp.derivative_work` for one of the derivatives and `nlp.factor_work` for a
    /// factorisation. A solve that reaches the bound ends with the candidate it has by then: verified if that
    /// passes every check, and with the status `workLimit` if not. The count depends on the plan alone, so the
    /// same plan under the same bound gives the same bytes. The default is more than nearly every plan that
    /// verifies at all needs: it ends the solves that would not have ended well.
    max_work: usize = 4_000_000,
};

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, plan: model.Plan, options: Options, diagnostics: *shared.core.diagnostics.Diagnostics) shared.core.diagnostics.InputError!Result {
    var preparation = std.heap.ArenaAllocator.init(allocator);
    defer preparation.deinit();
    var warm_start = std.heap.ArenaAllocator.init(allocator);
    defer warm_start.deinit();
    const memory = preparation.allocator();
    const prepared_rules = try rules.prepare(memory, &plan);
    const margins = try memory.alloc(f64, plan.rules.len);
    @memset(margins, 0);
    const counts = try memory.alloc(usize, plan.sections.len);
    @memset(counts, 2);
    var previous: ?candidate.Path = null;
    var iterations: usize = 0;
    var work: usize = 0;
    for (0..6) |pass| {
        var pass_arena = std.heap.ArenaAllocator.init(allocator);
        defer pass_arena.deinit();
        const temporary = pass_arena.allocator();
        const built_mesh = mesh.build(allocator, temporary, &plan, counts, if (previous) |*path| path else null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMesh => return diagnostics.forSource("").fail(.invalid_segment, null, "could not construct the trajectory mesh", .{}),
        };
        _ = warm_start.reset(.free_all);
        previous = null;
        const prepared = try problem.prepare(allocator, temporary, &prepared_rules, margins, built_mesh);
        var workspace = try problem.Workspace.init(temporary, &prepared.layout);
        const numerical = if (built_mesh.inconsistent)
            try initialReport(temporary, &prepared.layout, &workspace, prepared.x)
        else
            try nlp.solve(allocator, prepared.layout.numerical(), &workspace, prepared.x, .{ .max_work = (options.max_work -| work) / built_mesh.mesh.cells.len });
        iterations += numerical.inner_iterations;
        work +|= numerical.work *| built_mesh.mesh.cells.len;
        const current = try workspace.candidateOf(temporary, prepared.x);
        const validation = try verify.check(temporary, &prepared_rules, &current);
        const trajectory = try current.path.trajectory(temporary);
        const invalid = trajectory.invalid();
        const verified = !built_mesh.inconsistent and validation.feasible and validation.verified and invalid == null;
        const spent = numerical.status == .work_limit or work >= options.max_work;
        const done = numerical.status == .converged or numerical.status == .flat;
        var refine = false;
        var widest: f64 = 0;
        for (margins) |margin| widest = @max(widest, margin);
        const met = numerical.primal_violation <= verify.tolerance;
        if (!verified and !built_mesh.inconsistent and numerical.status != .invalid_initial and (met or widest > 0) and pass < 5 and !spent and (invalid == null or invalid.?.reason == error.PathOutOfRange)) {
            for (validation.refine_sections, counts) |needed, *count| if (needed or invalid != null) {
                count.* *= 2;
                refine = true;
            };
            // Margins the optimiser could not meet were too wide: they are cut, and the pass is made again. A rule
            // the verifier could not evaluate, which it reports as 1e300, has no overrun for a margin to take up.
            refine = refine or !met;
            if (refine) for (validation.rules, margins) |report, *margin| {
                if (!met) {
                    margin.* *= margin_relax;
                } else if (report.kind == .hard and report.violation > verify.tolerance and report.violation < 1e300) margin.* += margin_gain * report.violation;
            };
        }
        if (refine) {
            previous = try current.path.clone(warm_start.allocator());
            continue;
        }
        const path = try current.path.clone(result_allocator);
        const result: Result = .{
            .plan = plan,
            .path = path,
            .trajectory = try path.trajectory(result_allocator),
            .rule_reports = try result_allocator.dupe(RuleReport, validation.rules),
            .report = .{
                .status = if (built_mesh.inconsistent) .infeasible else if (verified) .converged else if (numerical.status == .invalid_initial) .numericalFailure else if (spent) .workLimit else if (!validation.feasible) .infeasible else if (!done) .iterationLimit else .verificationFailed,
                .feasible = !built_mesh.inconsistent and validation.feasible and invalid == null,
                .verified = verified,
                .settled = done or prepared.layout.objectives.len == 0,
                .iterations = iterations,
                .work = work,
                .objective = finite(numerical.objective, 0),
                .max_violation = finite(validation.max_violation, 1e300),
                .stationarity = finite(numerical.stationarity, 1e300),
            },
        };
        if (!verified) {
            if (invalid) |issue| try diagnostics.err(.invalid_segment, "rules", "candidate cannot be stored as a trajectory: {f}", .{issue});
            if (result.report.status == .workLimit) {
                try diagnostics.err(.invalid_segment, "rules", "trajectory solve reached its work bound of {d} before a candidate passed every check: maximum normalized violation {d}", .{ options.max_work, result.report.max_violation });
            } else try diagnostics.err(.invalid_segment, "rules", "trajectory solve {s}: maximum normalized violation {d}, stationarity {d}", .{ @tagName(result.report.status), result.report.max_violation, result.report.stationarity });
        } else if (!result.report.settled) {
            try diagnostics.warn(.invalid_segment, "rules", "the solve stopped before the soft rules settled: the path meets every hard rule, and a target or objective may be met less well than it can be", .{});
        }
        return result;
    }
    unreachable;
}

fn initialReport(allocator: std.mem.Allocator, layout: *const problem.Layout, workspace: *problem.Workspace, x: []const f64) std.mem.Allocator.Error!nlp.Report {
    const gradient = try allocator.alloc(f64, x.len);
    const constraints = try allocator.alloc(f64, layout.constraints.len);
    var report: nlp.Report = .{
        .status = .stalled,
        .objective = 0,
        .primal_violation = 0,
        .stationarity = 0,
        .complementarity = 0,
        .work = 1 + nlp.derivative_work,
        .penalty = 0,
    };
    workspace.values(x, .{ .objective = &report.objective, .constraints = constraints }) catch return invalidInitial();
    workspace.derivatives(x, .{
        .gradient = gradient,
        .jacobian = try allocator.alloc(f64, layout.columns.len),
        .soft = try allocator.alloc(f64, layout.soft_columns.len),
        .curved = try allocator.alloc(f64, layout.curved_offsets[layout.constraints.len]),
    }) catch return invalidInitial();
    for (constraints, 0..) |value, row| report.primal_violation = @max(report.primal_violation, if (row < layout.equality_count) @abs(value) else @max(0, -value));
    for (gradient, x, layout.lower, layout.upper) |value, variable, lower, upper| report.stationarity = @max(report.stationarity, @abs(variable - std.math.clamp(variable - value, lower, upper)));
    return report;
}

fn invalidInitial() nlp.Report {
    return .{
        .status = .invalid_initial,
        .objective = 0,
        .primal_violation = 1e300,
        .stationarity = 1e300,
        .complementarity = 0,
        .work = 1,
        .penalty = 0,
    };
}

fn finite(value: f64, fallback: f64) f64 {
    return if (std.math.isFinite(value)) value else fallback;
}
