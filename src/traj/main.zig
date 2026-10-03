const std = @import("std");
const pharos_traj = @import("pharos_traj");
const args = @import("cli/args.zig");
const flow = @import("cli/flow.zig");

pub fn main(init: std.process.Init) !void {
    return pharos_traj.cli.main(init, args, flow.run);
}
