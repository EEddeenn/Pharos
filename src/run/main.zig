const std = @import("std");
const pharos_run = @import("pharos_run");
const args = @import("cli/args.zig");
const flow = @import("cli/flow.zig");

pub fn main(init: std.process.Init) !void {
    return pharos_run.cli.main(init, args, flow.generate);
}
