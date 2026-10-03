const field = @import("../../codec.zig").field;

pub const Coefficients = @import("../../core.zig").iono.nequick.Coefficients;

pub const rows = [_]field.Field(Coefficients){
    .{ .name = "ai0", .width = 11, .scale_log2 = -2, .src = .{ .field = "ai0" } },
    .{ .name = "ai1", .width = 11, .repr = .twos, .scale_log2 = -8, .src = .{ .field = "ai1" } },
    .{ .name = "ai2", .width = 14, .repr = .twos, .scale_log2 = -15, .src = .{ .field = "ai2" } },
    .{ .name = "region", .width = 5, .src = .{ .constant = 0 } },
};
