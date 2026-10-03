const std = @import("std");
const shared = @import("shared");
const model = @import("plan.zig").model;
const mesh = @import("solve/mesh.zig");
const rules = @import("solve/rules.zig");
const problem = @import("solve/problem.zig");
const candidate = @import("solve/candidate.zig");
const nlp = @import("solve/nlp.zig");
const verify = @import("solve/verify.zig");

pub const RuleReport = verify.RuleReport;
pub const SampleState = candidate.SampleState;
pub const Status = enum { converged, iterationLimit, infeasible, numericalFailure, verificationFailed };
pub const Report = struct {
    status: Status,
    feasible: bool,
    verified: bool,
    iterations: usize,
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

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, plan: model.Plan, diagnostics: *shared.core.diagnostics.Diagnostics) shared.core.diagnostics.InputError!Result {
    var preparation = std.heap.ArenaAllocator.init(allocator);
    defer preparation.deinit();
    var warm_start = std.heap.ArenaAllocator.init(allocator);
    defer warm_start.deinit();
    const memory = preparation.allocator();
    const prepared_rules = try rules.prepare(memory, &plan);
    const counts = try memory.alloc(usize, plan.sections.len);
    @memset(counts, 2);
    var previous: ?candidate.Path = null;
    var iterations: usize = 0;
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
        const prepared = try problem.prepare(allocator, temporary, &prepared_rules, built_mesh);
        var workspace = try problem.Workspace.init(temporary, &prepared.layout);
        const numerical = if (built_mesh.inconsistent)
            try initialReport(temporary, &prepared.layout, &workspace, prepared.x)
        else
            try nlp.solve(allocator, prepared.layout.numerical(), &workspace, prepared.x, .{});
        iterations += numerical.inner_iterations;
        const current = try workspace.candidateOf(temporary, prepared.x);
        const validation = try verify.check(temporary, &prepared_rules, &current);
        const trajectory = try current.path.trajectory(temporary);
        const invalid = trajectory.invalid();
        const verified = !built_mesh.inconsistent and numerical.status == .converged and validation.feasible and validation.verified and invalid == null;
        var refine = false;
        if (!verified and !built_mesh.inconsistent and numerical.status != .invalid_initial and numerical.primal_violation <= verify.tolerance and pass < 5 and (invalid == null or invalid.?.reason == error.PathOutOfRange)) {
            for (validation.refine_sections, counts) |needed, *count| if (needed or invalid != null) {
                count.* *= 2;
                refine = true;
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
                .status = if (built_mesh.inconsistent) .infeasible else if (verified) .converged else if (numerical.status == .invalid_initial) .numericalFailure else if (!validation.feasible) .infeasible else if (numerical.status != .converged) .iterationLimit else .verificationFailed,
                .feasible = !built_mesh.inconsistent and validation.feasible and invalid == null,
                .verified = verified,
                .iterations = iterations,
                .objective = finite(numerical.objective, 0),
                .max_violation = finite(validation.max_violation, 1e300),
                .stationarity = finite(numerical.stationarity, 1e300),
            },
        };
        if (!verified) {
            if (invalid) |issue| try diagnostics.err(.invalid_segment, "rules", "candidate cannot be stored as a trajectory: {f}", .{issue});
            try diagnostics.err(.invalid_segment, "rules", "trajectory solve {s}: maximum normalized violation {d}, stationarity {d}", .{ @tagName(result.report.status), result.report.max_violation, result.report.stationarity });
        }
        return result;
    }
    unreachable;
}

fn initialReport(allocator: std.mem.Allocator, layout: *const problem.Layout, workspace: *problem.Workspace, x: []const f64) std.mem.Allocator.Error!nlp.Report {
    const gradient = try allocator.alloc(f64, x.len);
    const constraints = try allocator.alloc(f64, layout.constraints.len);
    const jacobian = try allocator.alloc(f64, layout.columns.len);
    var report: nlp.Report = .{
        .status = .stalled,
        .objective = 0,
        .primal_violation = 0,
        .stationarity = 0,
        .complementarity = 0,
        .outer_iterations = 0,
        .inner_iterations = 0,
        .evaluations = 1,
        .penalty = 0,
    };
    workspace.values(x, .{ .objective = &report.objective, .constraints = constraints }) catch return invalidInitial();
    workspace.derivatives(x, .{ .gradient = gradient, .jacobian = jacobian }) catch return invalidInitial();
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
        .outer_iterations = 0,
        .inner_iterations = 0,
        .evaluations = 1,
        .penalty = 0,
    };
}

fn finite(value: f64, fallback: f64) f64 {
    return if (std.math.isFinite(value)) value else fallback;
}
