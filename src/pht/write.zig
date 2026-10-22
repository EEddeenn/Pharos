const std = @import("std");
const header = @import("base/cache/header");
const codec = @import("base/cache/codec");
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;

pub fn write(w: *std.Io.Writer, value: Trajectory) std.Io.Writer.Error!void {
    try header.write(w, .pht);
    try codec.encode(w, Trajectory, value);
}
