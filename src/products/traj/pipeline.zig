//! A plan's text made a path: read, built and sampled, held against the receiver's domain and against the plan's
//! limits. A path outside the domain, or that breaks a limit, is kept, to be inspected, and is not written as a PHT.
const std = @import("std");
const diagnostics = @import("base/diagnostics");
const trajectory = @import("domain/trajectory/trajectory");
const model = @import("products/traj/input/model");
const construction = @import("products/traj/construction/build");
const plan_read = @import("products/traj/input/read");
const check = @import("products/traj/limits/check");

const Number = @import("base/text/number").Number;
const Range = @import("base/math/range").Range;

const Diagnostics = diagnostics.Diagnostics;

pub const Error = diagnostics.InputError;

pub const BuildStatus = enum { accepted, out_of_domain, limits_exceeded };

pub const Result = struct {
    plan: model.Plan,
    path: construction.Path,
    checks: []const check.Check,
    status: BuildStatus,

    pub fn refusal(self: *const Result) ?[]const u8 {
        return switch (self.status) {
            .accepted => null,
            .out_of_domain => "leaves the receiver's domain",
            .limits_exceeded => "breaks a limit of its plan",
        };
    }
};

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, text: []const u8, diags: *Diagnostics) Error!Result {
    const read = try plan_read.parse(result_allocator, text, diags);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const built = try construction.build(result_allocator, scratch.allocator(), &read, diags);
    var status: BuildStatus = .accepted;
    if (built.outside) |out| {
        try diags.err(.invalid_segment, try diags.arena.print("segments[{d}]", .{out.segment}), "the path leaves the receiver's domain at {f} s: {s}", .{ Number{ .value = out.time }, trajectory.reason(out.reason) });
        status = .out_of_domain;
    }
    const checks = try check.checkPath(allocator, result_allocator, &built.path, read.limits, read.altitude);
    for (read.limits, checks, 0..) |limit, c, i| {
        if (c.holds()) continue;
        const worst = c.worst.?;
        const q = limit.quantity;
        const range: Range = .{ .min = limit.bounds.min() orelse -std.math.inf(f64), .max = limit.bounds.max() orelse std.math.inf(f64) };
        // The value with its sign, in as many digits as show how far past its bound it lies.
        const bound = if (q.signed()) std.math.copysign(limit.bounds.max().?, worst.value) else if (worst.value > range.max) range.max else range.min;
        try diags.err(.out_of_range, try diags.arena.print("limits[{d}]", .{i}), "{s} must be {f} {s}{s}, got {f} {s} at {f} s; it first breaks at {f} s, in segments[{d}]", .{
            model.Quantity.names.get(q), range, q.unit(), if (q.signed()) " in size" else "", Number{ .value = worst.value, .past = bound }, q.unit(), Number{ .value = worst.time }, Number{ .value = c.broken[0].from }, c.broken[0].segment,
        });
        if (status == .accepted) status = .limits_exceeded;
    }
    return .{ .plan = read, .path = built.path, .checks = checks, .status = status };
}
