const std = @import("std");
const shared = @import("shared");
const model = @import("plan.zig").model;
const mesh = @import("solve/mesh.zig");
const rules = @import("solve/rules.zig");
const problem = @import("solve/problem.zig");
const candidate = @import("solve/candidate.zig");
const nlp = @import("solve/nlp.zig");
const convex = @import("solve/convex.zig");
const verify = @import("solve/verify.zig");

/// The optimiser holds a range at its own points only and leaves the path on the range's edge there, so that it
/// overruns between them. A rule's margin is how far inside its range the optimiser keeps the path at those points,
/// in the rule's normalised measure. A range the verifier finds overrun gets `margin_gain` times the overrun more
/// of it for the next pass: twice, because the path moves when it is held in, and may overrun elsewhere by more
/// than it did. A margin the optimiser then cannot meet is cut to `margin_relax` of it: to a quarter, because the
/// passes are six, and a margin that is too wide has to come down in one or two of them.
const margin_gain = 2;
const margin_relax = 0.25;
/// The convex tier makes no mesh of more cells than this many times its first mesh's, or than the first mesh with
/// one section grown from its two cells to `section_cells_most`, whichever is more: a "no" or an overrun on many
/// sections then costs a few times what the plan's first answer costs, and one section can still be made as fine
/// as six passes make it.
const refined_cells = 4;
const section_cells_most = 64;

pub const RuleReport = verify.RuleReport;
pub const SampleState = candidate.SampleState;
pub const Status = enum { converged, iterationLimit, workLimit, infeasible, numericalFailure, verificationFailed };
/// Which solve answered: the nonlinear one, or the convex tier (`convexBuild`).
pub const Tier = enum { nonlinear, convex };
pub const Report = struct {
    tier: Tier,
    /// The cells of the mesh the answer stands on, and the meshes the answer took.
    cells: usize,
    passes: usize,
    /// How many of those meshes' optima the verifier refused (the convex tier's; the nonlinear solve has no optimum
    /// to count where the plan states no soft rule).
    overruns: usize = 0,
    /// `infeasible` is said only where it is known of every path: of hard rules whose stated values contradict one
    /// another, and by the convex tier of a row no unknown moves. Its finest mesh that holds no path, like a
    /// nonlinear solve that finds none, ends with `iterationLimit`; the tier names the rules then, unless its own
    /// floor is among the rows that cannot hold together.
    status: Status,
    feasible: bool,
    verified: bool,
    /// Whether what the solve makes least was at its least when it stopped: in the nonlinear solve the plan's soft
    /// rules (true where it has none), in the convex tier its own measure of the path's smoothness.
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
    if (try convexBuild(allocator, result_allocator, plan, &prepared_rules, options, diagnostics)) |result| return result;
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
        const prepared = try problem.prepare(allocator, temporary, &prepared_rules, margins, built_mesh, false);
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
                .tier = .nonlinear,
                .cells = built_mesh.mesh.cells.len,
                .passes = pass + 1,
                .status = if (built_mesh.inconsistent) .infeasible else if (verified) .converged else if (numerical.status == .invalid_initial) .numericalFailure else if (spent) .workLimit else if (!validation.feasible or !done) .iterationLimit else .verificationFailed,
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
            try sayRests(diagnostics, validation.rests);
            if (built_mesh.inconsistent) {
                const named = try temporary.alloc(bool, plan.rules.len);
                @memset(named, false);
                for (built_mesh.conflict) |rule| if (rule) |index| {
                    named[index] = true;
                };
                try sayNone(diagnostics, named, null);
            } else {
                if (invalid) |issue| try diagnostics.err(.invalid_segment, "rules", "candidate cannot be stored as a trajectory: {f}", .{issue});
                if (result.report.status == .workLimit) {
                    try diagnostics.err(.invalid_segment, "rules", "trajectory solve reached its work bound of {d} before a candidate passed every check: maximum normalized violation {d}", .{ options.max_work, result.report.max_violation });
                } else try diagnostics.err(.invalid_segment, "rules", "trajectory solve {s}: maximum normalized violation {d}, stationarity {d}", .{ @tagName(result.report.status), result.report.max_violation, result.report.stationarity });
            }
        } else if (!result.report.settled) {
            try diagnostics.warn(.invalid_segment, "rules", "the solve stopped before the soft rules settled: the path meets every hard rule, and a target or objective may be met less well than it can be", .{});
        }
        return result;
    }
    unreachable;
}

/// The verifier's refusals of a rule that asks for a direction of travel where the path is at rest.
fn sayRests(diagnostics: *shared.core.diagnostics.Diagnostics, rests: []const ?f64) shared.core.diagnostics.InputError!void {
    for (rests, 0..) |rest, index| if (rest) |time| {
        try diagnostics.err(.invalid_segment, try diagnostics.arena.print("rules[{d}]", .{index}), "the path is at rest at {d} s, where this rule asks for a direction of travel: a path at rest has none", .{time});
    };
}

/// That no path meets the hard rules, or that the convex tier finds none on a mesh: at each rule of those that
/// cannot hold together, and once for the plan. `cells` null where what the plan states contradicts itself
/// whatever the path: the rules named, together with what the plan fixes, are then rules no path meets. Otherwise
/// it is what the convex tier finds on its mesh of so many pieces: the rules named are a set its programme cannot
/// meet on that mesh, not always the least such set, and a path of that mesh may still meet them, since the
/// programme holds the limits at the pieces' control points and, where a rule needs the frame, the frame where the
/// path was. A "no" with the tier's own floor among its rows is not said here (`convexBuild`).
fn sayNone(diagnostics: *shared.core.diagnostics.Diagnostics, named: []const bool, cells: ?usize) shared.core.diagnostics.InputError!void {
    var count: usize = 0;
    for (named) |is| count += @intFromBool(is);
    const others = if (count > 1) try diagnostics.arena.print(" together with the {d} other rule{s} named with it", .{ count - 1, if (count == 2) "" else "s" }) else "";
    const verb = if (count == 1) "is" else "are";
    for (named, 0..) |is, index| if (is) {
        const at = try diagnostics.arena.print("rules[{d}]", .{index});
        if (cells) |number| {
            try diagnostics.err(.invalid_segment, at, "the convex tier finds no path of {d} pieces that meets this rule{s} and what the plan fixes", .{ number, others });
        } else try diagnostics.err(.invalid_segment, at, "no path meets this rule{s} and what the plan fixes", .{others});
    };
    if (cells) |number| {
        try diagnostics.err(.invalid_segment, "rules", "the convex tier finds no path of {d} pieces that meets the hard rules: {d} of them {s} named", .{ number, count, verb });
    } else try diagnostics.err(.invalid_segment, "rules", "no path meets the hard rules: {d} of them {s} named", .{ count, verb });
}

/// The convex tier: the answer of a plan that states no target and no objective, whose events' times are held and
/// whose rules are convex in the path; null where the plan is not one. The answer is the path of least jerk, ties
/// by least acceleration (`convex.zig`). The mesh loop is the nonlinear solve's: a limit the verifier finds
/// overrun between the tier's rows gets a margin and its section more cells. A mesh that holds no path gets more
/// cells where the rows that cannot hold together stand, since a finer mesh may hold one; the "no" of the finest
/// is not decided, and names those rules, or none where the tier's floor is among them. A finer mesh is made only
/// of as many cells as `refined_cells` allows.
fn convexBuild(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, plan: model.Plan, prepared_rules: *const rules.Prepared, options: Options, diagnostics: *shared.core.diagnostics.Diagnostics) shared.core.diagnostics.InputError!?Result {
    const shape = rules.shape(prepared_rules);
    if (!shape.convex) return null;
    var preparation = std.heap.ArenaAllocator.init(allocator);
    defer preparation.deinit();
    var warm_start = std.heap.ArenaAllocator.init(allocator);
    defer warm_start.deinit();
    const memory = preparation.allocator();
    const tier_rules = try rules.floored(memory, prepared_rules.*);
    const margins = try memory.alloc(f64, plan.rules.len);
    @memset(margins, 0);
    const counts = try memory.alloc(usize, plan.sections.len);
    @memset(counts, 2);
    const named = try memory.alloc(bool, plan.rules.len);
    // The tier's answer is the optimum of its programme: a guessed state has no part in it.
    var seeded = plan;
    seeded.initial_guess.states = &.{};
    var previous: ?candidate.Path = null;
    var iterations: usize = 0;
    var work: usize = 0;
    var overruns: usize = 0;
    var most_cells: usize = 0;
    for (0..6) |pass| {
        var pass_arena = std.heap.ArenaAllocator.init(allocator);
        defer pass_arena.deinit();
        const temporary = pass_arena.allocator();
        const built_mesh = mesh.build(allocator, temporary, &seeded, counts, if (previous) |*path| path else null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMesh => return diagnostics.forSource("").fail(.invalid_segment, null, "could not construct the trajectory mesh", .{}),
        };
        for (built_mesh.mesh.durations) |column| if (built_mesh.lower[column] != built_mesh.upper[column]) return null;
        _ = warm_start.reset(.free_all);
        previous = null;
        const cells = built_mesh.mesh.cells.len;
        if (pass == 0) most_cells = @max(cells + section_cells_most - 2, refined_cells * cells);
        // The last mesh: the passes are done, or (below) the finer one would be of too many cells.
        var finest = pass == 5;
        const counted = try temporary.dupe(usize, counts);
        const prepared = try problem.prepare(allocator, temporary, &tier_rules, margins, built_mesh, true);
        var workspace = try problem.Workspace.init(temporary, &prepared.layout);
        workspace.hold_frame = true;
        const solved: convex.Report = if (built_mesh.inconsistent) .{ .outcome = .none } else try convex.solve(allocator, temporary, &prepared.layout, &workspace, prepared.x, shape.frame, (options.max_work -| work) / cells);
        iterations += solved.iterations;
        work +|= solved.work *| cells;
        const current = try workspace.candidateOf(temporary, prepared.x);
        const validation = try verify.check(temporary, prepared_rules, &current);
        const trajectory = try current.path.trajectory(temporary);
        const invalid = trajectory.invalid();
        const verified = !built_mesh.inconsistent and validation.feasible and validation.verified and invalid == null;
        const spent = solved.outcome == .spent or work >= options.max_work;
        if (solved.outcome == .optimal and !verified) overruns += 1;
        // The rules of the rows that cannot hold together, and the sections they stand on.
        @memset(named, false);
        var refine = false;
        // Whether a row of those stands on a cell: a finer mesh may then hold a path that this one does not.
        var finer = false;
        // Whether the tier's own floor is one of those rows: the "no" is then the floor's, no rule of the plan's.
        var floored = false;
        // A "no" met while a margin is in force is the margin's as much as the plan's: it is no answer.
        var widest: f64 = 0;
        for (margins) |margin| widest = @max(widest, margin);
        if (built_mesh.inconsistent) {
            for (built_mesh.conflict) |rule| if (rule) |index| {
                named[index] = true;
            };
        } else if ((solved.outcome == .none or solved.outcome == .unmet) and !verified) {
            for (solved.conflict) |row| {
                const term = prepared.layout.constraints[row];
                const check = tier_rules.checks[term.check().?];
                if (check.ruleIndex()) |rule| named[rule] = true;
                if (check.operation == .floor) floored = true;
                // A path that ends before a time some rule speaks of: that rule, and the one that ends the path.
                if (check.operation == .coverage) {
                    if (built_mesh.end_rule) |rule| named[rule] = true;
                    const end = current.path.totalDuration();
                    for (plan.rules, named) |rule, *is| switch (rule.scope) {
                        .time => |time| if (time > end) {
                            is.* = true;
                        },
                        .time_range => |range| if (range[1] > end) {
                            is.* = true;
                        },
                        else => {},
                    };
                }
                // Each section once, however many of its rows are named.
                const cell: ?usize = switch (prepared.layout.locations[term.point]) {
                    .cell => |place| place.index,
                    .control => |place| place.index,
                    else => null,
                };
                if (cell) |index| {
                    finer = true;
                    if (solved.outcome == .none and !finest and !spent) {
                        const section = built_mesh.mesh.cells[index].section;
                        const span = built_mesh.mesh.sections[section];
                        counts[section] = 2 * (span.end_cell - span.first_cell);
                        refine = true;
                    }
                }
            }
            // Where a margin stood in the way, the rules named lose theirs: the finer mesh is to hold what the
            // margin held (an overrun between the rows shrinks with the pieces; a margin can leave a narrow band
            // empty).
            if (solved.outcome == .none and widest > 0 and !finest and !spent) {
                var named_margin = false;
                for (margins, named) |*margin, is| if (is and margin.* > 0) {
                    margin.* = 0;
                    named_margin = true;
                };
                if (!named_margin) for (margins) |*margin| {
                    margin.* *= margin_relax;
                };
                refine = true;
            }
        } else if (!verified and solved.outcome != .invalid and !finest and !spent) {
            // An optimum that cannot be stored (it leaves the receiver's domain between its knots, or at them) is
            // the coarse mesh's: a finer one is tried.
            for (validation.refine_sections, counts) |needed, *count| if (needed or invalid != null) {
                count.* *= 2;
                refine = true;
            };
            if (refine) for (validation.rules, margins) |report, *margin| {
                if (report.kind == .hard and report.violation > verify.tolerance and report.violation < 1e300) margin.* += margin_gain * report.violation;
            };
        }
        if (refine) {
            var next: usize = 0;
            for (counts) |count| next += count;
            if (next > most_cells) {
                @memcpy(counts, counted);
                refine = false;
                finest = true;
            }
        }
        if (refine) {
            // A mesh that held no path, or none that can be stored, left no path to begin the next from: that one
            // begins from the seed.
            if (solved.outcome == .optimal and invalid == null) previous = try current.path.clone(warm_start.allocator());
            continue;
        }
        // What holds of every path: the plan's stated values contradict one another, or a row no unknown moves is
        // not met. The "no" of the finest mesh, or of one whose rows no finer mesh would change, is not decided:
        // the rules are named, unless the tier's floor, which is no rule of the plan's, is among the rows: then
        // nothing is. One that the work bound kept from a finer mesh is the bound's.
        const known = built_mesh.inconsistent or solved.outcome == .unmet;
        const undecided = solved.outcome == .none and !verified and widest == 0 and !(finer and !finest) and !floored;
        const path = try current.path.clone(result_allocator);
        const result: Result = .{
            .plan = plan,
            .path = path,
            .trajectory = try path.trajectory(result_allocator),
            .rule_reports = try result_allocator.dupe(RuleReport, validation.rules),
            .report = .{
                .tier = .convex,
                .cells = cells,
                .passes = pass + 1,
                .overruns = overruns,
                .status = if (verified) .converged else if (known) .infeasible else if (solved.outcome == .invalid) .numericalFailure else if (undecided) .iterationLimit else if (spent) .workLimit else if (solved.outcome == .undecided or floored) .iterationLimit else .verificationFailed,
                .feasible = !built_mesh.inconsistent and validation.feasible and invalid == null,
                .verified = verified,
                .settled = solved.outcome == .optimal,
                .iterations = iterations,
                .work = work,
                .objective = 0,
                .max_violation = finite(validation.max_violation, 1e300),
                .stationarity = 0,
            },
        };
        if (!verified) {
            try sayRests(diagnostics, validation.rests);
            if (known or undecided) {
                try sayNone(diagnostics, named, if (known) null else cells);
            } else {
                if (invalid) |issue| try diagnostics.err(.invalid_segment, "rules", "candidate cannot be stored as a trajectory: {f}", .{issue});
                if (result.report.status == .workLimit) {
                    try diagnostics.err(.invalid_segment, "rules", "trajectory solve reached its work bound of {d} before a candidate passed every check: maximum normalized violation {d}", .{ options.max_work, result.report.max_violation });
                } else try diagnostics.err(.invalid_segment, "rules", "trajectory solve {s}: maximum normalized violation {d}", .{ @tagName(result.report.status), result.report.max_violation });
            }
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
