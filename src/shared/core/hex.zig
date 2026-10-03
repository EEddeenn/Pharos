const std = @import("std");

const Double = struct {
    value: f64,

    pub fn format(self: Double, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("0x{x:0>16}", .{@as(u64, @bitCast(self.value))});
    }
};

pub fn double(value: f64) Double {
    return .{ .value = value };
}
