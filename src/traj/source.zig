//! A plan's text made a path: read, built and sampled, held against the receiver's domain and against the plan's
//! limits. A path outside the domain, or that breaks a limit, is kept, to be inspected, and is not written as a PHT.
const std = @import("std");
const shared = @import("shared");
const Diagnostics = shared.core.diagnostics.Diagnostics;
const Number = shared.json.node.Number;
const Range = shared.json.table.Range;
const plan = @import("plan.zig");
const path = @import("path.zig");
const check = @import("check.zig");

pub const Error = shared.core.diagnostics.InputError;

pub const Result = struct {
    plan: plan.model.Plan,
    trajectory: shared.trajectory.Trajectory,
    /// Each segment's first knot: the one the segment before ends at.
    first_knots: []const usize,
    /// When each segment ends.
    ends: []const f64,
    /// Each segment's length over the ground and the speed over the ground it ends at, in the plan's terms.
    lengths: []const f64,
    end_speeds: []const f64,
    /// Each limit of the plan, held against the path.
    checks: []const check.Check,
    /// Whether the path lies in the receiver's domain; and whether it does and keeps every limit.
    in_domain: bool,
    valid: bool,

    /// Why no PHT is written of the path, if none is.
    pub fn refusal(self: Result) ?[]const u8 {
        if (self.valid) return null;
        return if (self.in_domain) "breaks a limit of its plan" else "leaves the receiver's domain";
    }
};

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, text: []const u8, diags: *Diagnostics) Error!Result {
    const read = try plan.read.parse(result_allocator, text, diags);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const built = try path.build(result_allocator, scratch.allocator(), &read, diags);
    const trajectory: shared.trajectory.Trajectory = .{ .name = read.name, .knots = built.knots };
    var in_domain = true;
    if (built.outside) |out| {
        // Where the built motion leaves the domain, its time and the bound it breaks.
        try diags.err(.invalid_segment, try diags.arena.print("segments[{d}]", .{out.segment}), "the path leaves the receiver's domain at {f} s: {s}", .{ Number{ .value = out.time }, shared.trajectory.reason(out.reason) });
        in_domain = false;
    } else if (trajectory.invalid()) |bad| {
        const at = bad.location.?;
        // The segment of the piece that ends at the knot.
        var segment: usize = 0;
        while (segment + 1 < built.first_knots.len and built.first_knots[segment + 1] < at.knot) segment += 1;
        try diags.err(.invalid_segment, try diags.arena.print("segments[{d}]", .{segment}), "the path leaves the receiver's domain at {f} s: {s}", .{ Number{ .value = at.t }, shared.trajectory.reason(bad.reason) });
        in_domain = false;
    }
    var valid = in_domain;
    const checks = try check.run(allocator, result_allocator, built.knots, built.first_knots, &read);
    for (read.limits, checks, 0..) |limit, c, i| {
        if (c.holds) continue;
        const worst = c.worst.?;
        const q = limit.quantity;
        const range: Range = .{ .min = limit.min orelse -std.math.inf(f64), .max = limit.max orelse std.math.inf(f64) };
        // The value with its sign, in as many digits as show how far past its bound it lies.
        const bound = if (q.signed()) std.math.copysign(limit.max.?, worst.value) else if (worst.value > range.max) range.max else range.min;
        try diags.err(.out_of_range, try diags.arena.print("limits[{d}]", .{i}), "{s} must be {f} {s}{s}, got {f} {s} at {f} s; it first breaks at {f} s, in segments[{d}]", .{
            plan.model.Quantity.names.get(q), range, q.unit(), if (q.signed()) " in size" else "", Number{ .value = worst.value, .past = bound }, q.unit(), Number{ .value = worst.time }, Number{ .value = c.broken[0].from }, c.broken[0].segment,
        });
        valid = false;
    }
    return .{ .plan = read, .trajectory = trajectory, .first_knots = built.first_knots, .ends = built.ends, .lengths = built.lengths, .end_speeds = built.end_speeds, .checks = checks, .in_domain = in_domain, .valid = valid };
}
