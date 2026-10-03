const std = @import("std");
const pharos_pack = @import("pharos_pack");
const args = @import("cli/args.zig");
const flow = @import("cli/flow.zig");

pub fn main(init: std.process.Init) !void {
    return pharos_pack.cli.main(init, args, flow.pack);
}
