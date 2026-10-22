const std = @import("std");

pub const Error = error{Malformed};

pub fn readFloats(text: []const u8, outs: []const []f64) Error!void {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    for (outs) |out| for (out) |*v| {
        const token = it.next() orelse return error.Malformed;
        v.* = std.fmt.parseFloat(f64, token) catch return error.Malformed;
    };
    if (it.next() != null) return error.Malformed;
}
