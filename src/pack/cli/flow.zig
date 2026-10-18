const std = @import("std");
const Io = std.Io;
const pharos_pack = @import("pharos_pack");
const Diagnostics = pharos_pack.core.diagnostics.Diagnostics;
const Escaped = pharos_pack.core.diagnostics.Escaped;
const bundle = pharos_pack.bundle;
const Args = @import("args.zig").Args;
const cli = pharos_pack.cli;
const Console = cli.Console;

const max_scenario_bytes = 64 << 20;

pub fn pack(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    console.info("Loading scenario: {f}", .{Escaped{ .text = args.input }});
    const text = (cli.readFile(io, arena.allocator(), args.input, max_scenario_bytes, console) catch return cli.outOfMemory(console)) orelse return 1;
    var diags: Diagnostics = .{ .arena = arena.allocator(), .source = args.input };
    const assembled = pharos_pack.assemble.assemble(arena.allocator(), .{ .dir = .{ .io = io, .base = Io.Dir.path.dirname(args.input) } }, text, &diags) catch |e| {
        cli.printDiagnostics(console, &diags);
        switch (e) {
            error.OutOfMemory => return cli.outOfMemory(console),
            error.InvalidInput, error.IoFailed => {},
        }
        console.flush();
        return 1;
    };
    cli.printDiagnostics(console, &diags);
    report(console, &assembled);
    if (args.dry_run) return 0;
    const path = args.output orelse cli.withExtension(arena.allocator(), args.input, "phb") catch return cli.outOfMemory(console);
    write(io, path, &assembled.bundle) catch |e| {
        cli.cannotWrite(console, path, e);
        return 1;
    };
    console.info("Bundle written: {f}", .{Escaped{ .text = path }});
    console.flush();
    return 0;
}

fn write(io: Io, path: []const u8, b: *const bundle.Bundle) !void {
    var out: cli.FileWriter = undefined;
    try out.open(io, path);
    const written = if (bundle.format.write(out.interface(), b)) true else |_| false;
    try out.finish(io);
    if (!written) return error.WriteFailed;
}

fn report(console: Console, assembled: *const pharos_pack.assemble.Assembled) void {
    const b = &assembled.bundle;
    const s = &b.scenario;
    cli.reportTrajectory(console, &b.trajectory, s.trajectory_file);
    cli.reportSpan(console, assembled.span, b.plan.leap);
    if (assembled.skipped > 0) console.info("{d} navigation records skipped (other systems, RINEX 4 blocks or slots the core does not model, values outside their ranges)", .{assembled.skipped});
    cli.reportNavigation(console, b);
    cli.reportServices(console, s);
    console.flush();
}
