const std = @import("std");
const pharos_obs = @import("pharos_obs");
const args = @import("cli/args.zig");
const flow = @import("cli/flow.zig");

pub fn main(init: std.process.Init) !void {
    return pharos_obs.cli.main(init, args, flow.write);
}
