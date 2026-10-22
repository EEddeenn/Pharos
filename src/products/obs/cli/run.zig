const std = @import("std");
const diagnostics = @import("base/diagnostics");
const cli_console = @import("interface/cli/console");
const cli_files = @import("interface/cli/files");
const cli_phb = @import("interface/cli/phb");
const cli_reports = @import("interface/cli/reports");
const args_mod = @import("products/obs/cli/args");
const session = @import("products/obs/output/session");

const Io = std.Io;
const PreparedScenario = @import("simulation/model/prepared_scenario").PreparedScenario;
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;
const Epoch = @import("domain/time/gps").Epoch;
const File = session.File;
const OutputKind = session.OutputKind;
const OutputRequest = session.OutputRequest;
const Created = session.Created;
const Console = cli_console.Console;
const CliError = cli_console.Error;
const Escaped = diagnostics.Escaped;
const Args = args_mod.Args;
const Action = union(enum) { check, write: []const u8 };

const From = struct {
    ms: ?u64,

    pub fn format(self: From, writer: *Io.Writer) Io.Writer.Error!void {
        if (self.ms) |ms| try writer.print(" from epoch {d}", .{ms});
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) CliError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bundle = try cli_phb.load(io, gpa, arena, args.input, console);
    const scenario = &bundle.scenario;
    const config = &scenario.config;
    if (config.observation == null and config.position == null) {
        console.fail("The bundle declares no observation or position file: pharos-run generates its samples", .{});
        return error.Reported;
    }
    if (config.observation == null) {
        if (args.observation != null) warnIgnored(console, .observation, "--observation");
        if (args.created != null) warnIgnored(console, .observation, "--created");
    }
    if (config.position == null and args.position != null) warnIgnored(console, .position, "--position");
    const trajectory: Trajectory = .{ .name = bundle.display.names.trajectory_name, .knots = scenario.trajectory.knots };
    cli_reports.reportTrajectory(console, &trajectory, bundle.display.names.trajectory_file);
    cli_reports.reportNavigation(console, &bundle);
    cli_reports.reportCoverage(console, scenario);

    var failure: ?CliError = null;
    if (config.observation != null) observation: {
        const created = args.created orelse (readClock(io, console) catch |err| {
            rememberFailure(&failure, err);
            break :observation;
        });
        const action = actionFor(arena, args.mode, args.input, args.observation, "obs") catch |err| {
            rememberFailure(&failure, err);
            break :observation;
        };
        runOutput(gpa, io, scenario, .{ .observation = created }, args.seek, action, console) catch |err| rememberFailure(&failure, err);
    }
    if (config.position) |position| position_output: {
        const action = actionFor(arena, args.mode, args.input, args.position, position.format.extension()) catch |err| {
            rememberFailure(&failure, err);
            break :position_output;
        };
        runOutput(gpa, io, scenario, .position, args.seek, action, console) catch |err| rememberFailure(&failure, err);
    }
    if (failure) |err| return err;
}

fn rememberFailure(failure: *?CliError, err: CliError) void {
    if (failure.* == null or err == error.OutOfMemory) failure.* = err;
}

fn actionFor(arena: std.mem.Allocator, mode: args_mod.Mode, input: []const u8, output: ?[]const u8, extension: []const u8) std.mem.Allocator.Error!Action {
    return switch (mode) {
        .check => .check,
        .write => .{ .write = output orelse try cli_files.withExtension(arena, input, extension) },
    };
}

fn warnIgnored(console: Console, output: OutputKind, option: []const u8) void {
    console.warn("The bundle declares no {s} file: {s} is ignored", .{ OutputKind.words.get(output), option });
}

fn readClock(io: Io, console: Console) CliError!Created {
    var read_s: i64 = 0;
    return Created.fromWallClock(io, &read_s) orelse {
        console.fail("The wall clock must read from {d} to {d} s, got {d}", .{ Created.min.unix_s, Created.max.unix_s, read_s });
        return error.Reported;
    };
}

fn runOutput(gpa: std.mem.Allocator, io: Io, scenario: *const PreparedScenario, request: OutputRequest, first: ?Epoch, action: Action, console: Console) CliError!void {
    const kind: OutputKind = request;
    const file = File.create(gpa, scenario, request) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        console.fail("Cannot create the {s} file: {s}", .{ OutputKind.words.get(kind), session.reason(err) });
        return error.Reported;
    };
    defer file.destroy();
    if (first) |epoch| file.setRange(.{ .first = epoch.ms, .end = file.fullRange().end }) catch |err| {
        console.fail("--seek {d} cannot select the {s} file's epochs: {s}", .{ epoch.ms, OutputKind.words.get(kind), switch (err) {
            error.Begun => "the file has begun",
            error.EpochOutOfRange => "the range goes beyond the run",
            error.EmptyRange => "no epoch of the run is left from it",
            error.NoEpochs => "the file has no epoch from it on",
        } });
        return error.Reported;
    };
    if (file.ionosphere()) |info| cli_reports.printIonosphere(console, info);
    const title = switch (kind) {
        .observation => "Observation file",
        .position => "Position file",
    };
    const summary = file.summary();
    const from: From = .{ .ms = if (first != null) summary.first_ms else null };
    if (summary.tracked) |tracked| {
        console.info("{s}: {d} epochs every {d} ms{f}, {d} satellites tracked", .{ title, summary.epochs, summary.interval_ms, from, tracked });
    } else console.info("{s}: {d} epochs every {d} ms{f}", .{ title, summary.epochs, summary.interval_ms, from });
    console.flush();
    const path = switch (action) {
        .check => return,
        .write => |output_path| output_path,
    };
    var out: cli_files.FileWriter = undefined;
    out.open(io, path) catch |err| {
        cli_files.cannotWrite(console, path, err);
        return error.Reported;
    };
    defer out.close(io);
    const written = writeBatches(file, out.interface());
    out.flush() catch |err| {
        cli_files.cannotWrite(console, path, err);
        return error.Reported;
    };
    written catch |err| {
        cli_files.cannotWrite(console, path, out.writer.err orelse err);
        return error.Reported;
    };
    console.info("{s} written: {f}", .{ title, Escaped{ .text = path } });
    console.flush();
}

fn writeBatches(file: *File, writer: *Io.Writer) Io.Writer.Error!void {
    while (true) {
        const batch = file.pull(session.max_batch_epochs) catch unreachable;
        try writer.writeAll(batch.bytes);
        if (batch.end) return;
    }
}
