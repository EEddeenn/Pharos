const std = @import("std");
const cli_process = @import("interface/cli/process");
const args = @import("products/traj/cli/args");
const flow = @import("products/traj/cli/run");

pub fn main(init: std.process.Init) !void {
    return cli_process.main(init, args, flow.run);
}
