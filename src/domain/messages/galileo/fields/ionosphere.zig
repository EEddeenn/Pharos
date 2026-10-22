const nequick = @import("domain/propagation/ionosphere/nequick");
const field = @import("base/binary/field");
pub const Coefficients = nequick.Coefficients;
pub const rows = [_]field.Field(Coefficients){
    .{ .name = "ai0", .width = 11, .scale_log2 = -2, .src = .{ .field = "ai0" } },
    .{ .name = "ai1", .width = 11, .repr = .twos, .scale_log2 = -8, .src = .{ .field = "ai1" } },
    .{ .name = "ai2", .width = 14, .repr = .twos, .scale_log2 = -15, .src = .{ .field = "ai2" } },
    .{ .name = "region", .width = 5, .src = .{ .constant = 0 } },
};

pub const Codes = field.Decoded(Coefficients, &rows);
