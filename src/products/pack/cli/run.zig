const std = @import("std");
const diagnostics = @import("base/diagnostics");
const cli_console = @import("interface/cli/console");
const cli_diagnostics = @import("interface/cli/diagnostics");
const cli_files = @import("interface/cli/files");
const cli_reports = @import("interface/cli/reports");
const phb_write = @import("phb/write");
const pipeline = @import("products/pack/pipeline");
const scenario_read = @import("products/pack/input/scenario/read");

const Io = std.Io;
const Diagnostics = diagnostics.Diagnostics;
const Escaped = diagnostics.Escaped;
const Console = cli_console.Console;
const CliError = cli_console.Error;
const Args = @import("products/pack/cli/args").Args;
const File = @import("phb/model/file").File;
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;
const max_scenario_bytes = 64 << 20;

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) CliError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    console.info("Loading scenario: {f}", .{Escaped{ .text = args.input }});
    const text = try cli_files.readFile(io, arena, args.input, max_scenario_bytes, console);
    var diags: Diagnostics = .{ .arena = arena, .source = args.input };
    const request = scenario_read.readRequest(arena, text, &diags) catch |err| return cli_diagnostics.reportFailure(console, &diags, err);
    const assembled = pipeline.assemble(arena, .{ .dir = .{ .io = io, .base = Io.Dir.path.dirname(args.input) } }, &request, &diags) catch |err| return cli_diagnostics.reportFailure(console, &diags, err);
    cli_diagnostics.printDiagnostics(console, &diags);
    report(console, &assembled);
    const requested = switch (args.operation) {
        .check => return,
        .write => |path| path,
    };
    const path = requested orelse try cli_files.withExtension(arena, args.input, "phb");
    write(io, path, &assembled.file) catch |err| {
        cli_files.cannotWrite(console, path, err);
        return error.Reported;
    };
    console.info("Bundle written: {f}", .{Escaped{ .text = path }});
    console.flush();
}

fn write(io: Io, path: []const u8, file: *const File) (Io.File.OpenError || Io.File.Writer.Error || Io.Writer.Error)!void {
    var out: cli_files.FileWriter = undefined;
    try out.open(io, path);
    defer out.close(io);
    const written = phb_write.write(out.interface(), file);
    try out.flush();
    try written;
}

fn report(console: Console, assembled: *const pipeline.Assembled) void {
    const bundle = &assembled.bundle;
    const scenario = &bundle.scenario;
    const trajectory: Trajectory = .{ .name = bundle.display.names.trajectory_name, .knots = scenario.trajectory.knots };
    cli_reports.reportTrajectory(console, &trajectory, bundle.display.names.trajectory_file);
    cli_reports.reportSpan(console, scenario.span(), scenario.flight_plan.leap);
    cli_reports.reportNavigation(console, bundle);
    cli_reports.reportServices(console, &scenario.config);
    console.flush();
}
