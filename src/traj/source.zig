const std = @import("std");
const shared = @import("shared");
const plan = @import("plan.zig");
const solve = @import("solve.zig");
pub const Error = shared.core.diagnostics.InputError;
pub const Result = solve.Result;
pub const Options = solve.Options;

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, text: []const u8, options: Options, diags: *shared.core.diagnostics.Diagnostics) Error!Result {
    const program = try plan.read.parse(result_allocator, text, diags);
    return solve.build(allocator, result_allocator, program, options, diags);
}
