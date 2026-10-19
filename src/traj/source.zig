//! A plan's text made a path: read, built and sampled, and held against the receiver's domain. A path outside it
//! is kept, to be inspected, and is not written as a PHT.
const std = @import("std");
const shared = @import("shared");
const Diagnostics = shared.core.diagnostics.Diagnostics;
const Number = shared.json.node.Number;
const plan = @import("plan.zig");
const path = @import("path.zig");

pub const Error = shared.core.diagnostics.InputError;

pub const Result = struct {
    plan: plan.model.Plan,
    trajectory: shared.trajectory.Trajectory,
    /// Each segment's first knot: the one the segment before ends at.
    first_knots: []const usize,
    /// When each segment ends.
    ends: []const f64,
    /// Whether the path lies in the receiver's domain.
    valid: bool,
};

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, text: []const u8, diags: *Diagnostics) Error!Result {
    const read = try plan.read.parse(result_allocator, text, diags);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const built = try path.build(result_allocator, scratch.allocator(), &read, diags);
    const trajectory: shared.trajectory.Trajectory = .{ .name = read.name, .knots = built.knots };
    var valid = true;
    if (built.outside) |out| {
        // Where the built motion leaves the domain, its time and the bound it breaks.
        try diags.err(.invalid_segment, try diags.arena.print("segments[{d}]", .{out.segment}), "the path leaves the receiver's domain at {f} s: {s}", .{ Number{ .value = out.time }, shared.trajectory.reason(out.reason) });
        valid = false;
    } else if (trajectory.invalid()) |bad| {
        const at = bad.location.?;
        // The segment of the piece that ends at the knot.
        var segment: usize = 0;
        while (segment + 1 < built.first_knots.len and built.first_knots[segment + 1] < at.knot) segment += 1;
        try diags.err(.invalid_segment, try diags.arena.print("segments[{d}]", .{segment}), "the path leaves the receiver's domain at {f} s: {s}", .{ Number{ .value = at.t }, shared.trajectory.reason(bad.reason) });
        valid = false;
    }
    return .{ .plan = read, .trajectory = trajectory, .first_knots = built.first_knots, .ends = built.ends, .valid = valid };
}
