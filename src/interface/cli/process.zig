const std = @import("std");
const build_info = @import("build_info");
const cli_console = @import("interface/cli/console");
const arguments = @import("interface/cli/arguments");

const Io = std.Io;
const Console = cli_console.Console;

pub fn main(init: std.process.Init, comptime Line: type, comptime run: fn (std.mem.Allocator, Io, Line.Args, Console) cli_console.Error!void) !void {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const console: Console = .{ .out = &stdout_writer.interface, .err = &stderr_writer.interface };
    var failed = false;
    dispatch(init, Line, run, console) catch |err| {
        failed = true;
        switch (err) {
            error.OutOfMemory => console.fail("Out of memory", .{}),
            error.Reported => {},
        }
    };
    console.flush();
    const lost = stdout_writer.err != null or stderr_writer.err != null;
    if (failed or lost) std.process.exit(1);
}

fn dispatch(init: std.process.Init, comptime Line: type, comptime run: fn (std.mem.Allocator, Io, Line.Args, Console) cli_console.Error!void, console: Console) cli_console.Error!void {
    const all = init.minimal.args.toSlice(init.arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => {
            console.fail("Arguments could not be read", .{});
            return error.Reported;
        },
    };
    const argv = all[@min(all.len, 1)..];
    if (arguments.wanted(Line.tool, Line.Name, Line.options, argv)) |request| {
        switch (request) {
            .help => console.print("{s}", .{Line.usage}),
            .version => {
                const v = Line.tool.version;
                console.print("{s} {d}.{d}.{d} {x:0>16}\n", .{ Line.tool.name, v.major, v.minor, v.patch, build_info.source_digest });
            },
        }
        return;
    }
    var refusal: arguments.Refusal = undefined;
    const args = Line.parse(argv, &refusal) catch {
        console.fail("{f}", .{refusal});
        return error.Reported;
    };
    try run(init.gpa, init.io, args, console);
}
