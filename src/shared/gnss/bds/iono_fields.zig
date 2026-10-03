const std = @import("std");
const codec = @import("../../codec.zig");
const field = codec.field;

pub const Coefficients = [9]f64;

fn bdgimAlpha(comptime k: usize) fn (*const Coefficients) f64 {
    return struct {
        fn f(coefficients: *const Coefficients) f64 {
            return if (k == 4) -coefficients[k] else coefficients[k];
        }
    }.f;
}

pub const bdgim = [9]field.Field(Coefficients){
    .{ .name = "bdgim_alpha1", .width = 10, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(0) } },
    .{ .name = "bdgim_alpha2", .width = 8, .repr = .twos, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(1) } },
    .{ .name = "bdgim_alpha3", .width = 8, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(2) } },
    .{ .name = "bdgim_alpha4", .width = 8, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(3) } },
    .{ .name = "bdgim_alpha5", .width = 8, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(4) } },
    .{ .name = "bdgim_alpha6", .width = 8, .repr = .twos, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(5) } },
    .{ .name = "bdgim_alpha7", .width = 8, .repr = .twos, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(6) } },
    .{ .name = "bdgim_alpha8", .width = 8, .repr = .twos, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(7) } },
    .{ .name = "bdgim_alpha9", .width = 8, .repr = .twos, .scale_log2 = -3, .src = .{ .computed = &bdgimAlpha(8) } },
};

comptime {
    std.debug.assert(field.totalWidth(Coefficients, &bdgim) == 74);
}
