const std = @import("std");
const diagnostics = @import("base/diagnostics");
const time = @import("domain/time/gps");
const cli_console = @import("interface/cli/console");
const cli_files = @import("interface/cli/files");
const cli_phb = @import("interface/cli/phb");
const cli_reports = @import("interface/cli/reports");
const args_mod = @import("products/run/cli/args");
const engine_run = @import("products/run/engine/run");
const output_dump = @import("products/run/output/dump");
const output_sink = @import("products/run/output/sink");
const output_tag = @import("products/run/output/tag");

const Io = std.Io;
const Number = @import("base/text/number").Number;
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;
const PreparedBundle = @import("phb/prepared").PreparedBundle;
const PreparedScenario = @import("simulation/model/prepared_scenario").PreparedScenario;
const Samples = @import("simulation/model/config").Samples;
const replan_epochs = @import("simulation/state/channels").replan_epochs;
const Event = @import("products/run/engine/events").Event;
const GpsTime = time.GpsTime;
const Epoch = time.Epoch;
const Run = engine_run.Run;
const Console = cli_console.Console;
const CliError = cli_console.Error;
const Escaped = diagnostics.Escaped;
const Args = args_mod.Args;
const progress_every_epochs = 10_000;

const Progress = struct {
    console: Console,
    scenario: *const PreparedScenario,
    before_replan: ?usize,
};

const DumpFiles = struct {
    entries: [names.len]Entry = undefined,
    opened_count: usize = 0,

    const names = [_][]const u8{ "rows.txt", "plan.txt", "params.txt" };
    const Entry = struct { path: []const u8, output: cli_files.FileWriter };

    fn open(self: *DumpFiles, arena: std.mem.Allocator, io: Io, dir: []const u8, console: Console) CliError!void {
        for (names, 0..) |name, i| {
            const entry = &self.entries[i];
            entry.path = try Io.Dir.path.join(arena, &.{ dir, name });
            entry.output.open(io, entry.path) catch |err| {
                cli_files.cannotWrite(console, entry.path, err);
                return error.Reported;
            };
            self.opened_count += 1;
        }
    }

    fn close(self: *DumpFiles, io: Io) void {
        for (self.entries[0..self.opened_count]) |*entry| entry.output.close(io);
        self.opened_count = 0;
    }

    fn writers(self: *DumpFiles) engine_run.DumpWriters {
        if (self.opened_count == 0) return .{};
        return .{ .rows = self.entries[0].output.interface(), .plan = self.entries[1].output.interface(), .params = self.entries[2].output.interface() };
    }

    fn flush(self: *DumpFiles, console: Console) CliError!void {
        var failed = false;
        for (self.entries[0..self.opened_count]) |*entry| entry.output.flush() catch |err| {
            cli_files.cannotWrite(console, entry.path, err);
            failed = true;
        };
        if (failed) return error.Reported;
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) CliError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bundle = try cli_phb.load(io, gpa, arena, args.input, console);
    var dumps: DumpFiles = .{};
    defer dumps.close(io);
    const generated = generate(gpa, arena, io, &bundle, args, &dumps, console);
    const flushed = dumps.flush(console);
    try generated;
    try flushed;
}

fn generate(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, bundle: *const PreparedBundle, args: Args, dumps: *DumpFiles, console: Console) CliError!void {
    if (bundle.scenario.config.samples == null) {
        console.fail("The bundle has no samples block: nothing to generate", .{});
        return error.Reported;
    }
    switch (args.operation) {
        .check => {},
        .write => |requested| if (requested.dump) |dir| {
            try makeDumpDir(io, dir, console);
            try dumps.open(arena, io, dir, console);
        },
    }
    const engine = Run.create(gpa, &bundle.scenario, args.options, dumps.writers()) catch |err| switch (err) {
        error.NoSamples => unreachable, // Checked before opening dump files.
        error.OutOfMemory => return error.OutOfMemory,
        error.ThreadSpawnFailed => {
            console.fail("Cannot create the run: {s}", .{engine_run.reason(err)});
            return error.Reported;
        },
    };
    defer engine.destroy();
    if (args.seek) |target| engine.seek(target) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        reportSeekError(console, engine, target, err);
        return error.Reported;
    };
    const writing = switch (args.operation) {
        .check => {
            _ = report(console, bundle, engine, args.seek != null);
            return;
        },
        .write => |requested| requested,
    };
    const output_path = writing.output orelse try cli_files.withExtension(arena, args.input, "bin");
    if (writing.dump) |dir| try writeScenarioDump(arena, io, dir, bundle, console);
    if (writing.tag) {
        const info = engine.info();
        const status = engine.status();
        try writeTag(arena, io, info.samples, time.atEpoch(info.span.start, status.entry_epoch), output_path, console);
    }
    var progress: Progress = .{ .console = console, .scenario = &bundle.scenario, .before_replan = report(console, bundle, engine, args.seek != null) };
    try writeSamples(gpa, io, engine, output_path, &progress);
}

fn report(console: Console, bundle: *const PreparedBundle, engine: *Run, seeking: bool) ?usize {
    const scenario = &bundle.scenario;
    const info = engine.info();
    const status = engine.status();
    const trajectory: Trajectory = .{ .name = bundle.display.names.trajectory_name, .knots = scenario.trajectory.knots };
    cli_reports.reportTrajectory(console, &trajectory, bundle.display.names.trajectory_file);
    cli_reports.reportSpan(console, info.span, scenario.flight_plan.leap);
    cli_reports.reportNavigation(console, bundle);
    cli_reports.reportCoverage(console, scenario);
    cli_reports.reportServices(console, &scenario.config);
    cli_reports.printIonosphere(console, engine.ionosphere());
    const samples = info.samples;
    console.info("Sampling: {s} at {d} MHz, centre {d} MHz: {d} samples, {d} bytes per epoch", .{ samples.format.name(), samples.sample_rate.mhz(), samples.center.mhz(), info.samples_per_epoch, info.bytes_per_epoch });
    const noise = engine_run.NoiseMode.words.get(info.noise);
    switch (status.gain) {
        .adaptive => console.info("Options: workers {d}, seed {d}, noise {s}, gain adaptive", .{ info.workers, info.seed, noise }),
        .constant => |level| console.info("Options: workers {d}, seed {d}, noise {s}, gain constant {f} dB", .{ info.workers, info.seed, noise, Number{ .value = level.db } }),
    }
    if (seeking) console.info("Starting at epoch {d} of {d}, {f}", .{ status.entry_epoch.ms, info.span.epochs, time.atEpoch(info.span.start, status.entry_epoch).printed(null) });
    return reportChannels(console, scenario, engine, status.entry_epoch);
}

fn reportChannels(console: Console, scenario: *const PreparedScenario, engine: *Run, entry: Epoch) ?usize {
    var held: usize = 0;
    while (engine.nextEvent()) |event| {
        if (event == .channel_added) held += 1;
        reportEvent(console, event);
    }
    if (entry.ms != 0 and entry.ms % replan_epochs == 0) return held;
    if (held == 0) warnNoChannel(console, scenario, entry);
    return null;
}

fn warnNoChannel(console: Console, scenario: *const PreparedScenario, entry: Epoch) void {
    if (scenario.flight_plan.fliesAt(&scenario.config, time.atEpoch(scenario.config.start, entry))) {
        console.warn("No channel at epoch {d}: no satellite flying a listed signal there stands above the elevation mask; the samples carry noise alone", .{entry.ms});
    } else console.warn("No channel at epoch {d}: no satellite flies a listed signal there; the samples carry noise alone", .{entry.ms});
}

fn writeSamples(gpa: std.mem.Allocator, io: Io, engine: *Run, output_path: []const u8, progress: *Progress) CliError!void {
    const console = progress.console;
    console.flush();
    const start = Io.Clock.Timestamp.now(io, .awake);
    const written = output_sink.writeRun(gpa, io, output_path, engine, progress, reportBlock) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        cli_files.cannotWrite(console, output_path, err);
        return error.Reported;
    };
    const elapsed_ns: f64 = @floatFromInt(start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
    const info = engine.info();
    const status = engine.status();
    if (written.failure) |err| if (err != error.OutOfMemory) reportStop(console, status, info.span.epochs, err);
    if (written.write_failure) |err| cli_files.cannotWrite(console, output_path, err);
    printSummary(console, info, status, output_path, written.bytes_on_file, elapsed_ns / 1e9);
    if (written.failure) |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (written.failure != null or written.write_failure != null) return error.Reported;
}

fn reportSeekError(console: Console, engine: *const Run, target: Epoch, err: engine_run.SeekError) void {
    const info = engine.info();
    const status = engine.status();
    switch (err) {
        error.EpochOutOfRange => console.fail("--seek must be at most {d}, got {d}", .{ info.span.epochs, target.ms }),
        error.AdaptiveGain => console.fail("--seek needs --gain: {s}", .{engine_run.reason(err)}),
        error.CommandsApplied => unreachable,
        else => |failure| reportStop(console, status, info.span.epochs, failure),
    }
}

fn reportStop(console: Console, status: engine_run.Status, epochs: u64, err: engine_run.GenerationError) void {
    console.fail("Epoch {d} of {d} could not be generated: {s}", .{ status.epoch.ms, epochs, engine_run.reason(err) });
}

fn reportBlock(progress: *Progress, engine: *Run, block: engine_run.Block) void {
    const status = engine.status();
    const entry = status.entry_epoch;
    while (engine.nextEvent()) |event| {
        if (progress.before_replan) |*held| switch (event) {
            .channel_added => |channel| if (channel.epoch.ms == entry.ms) {
                held.* += 1;
            },
            .channel_removed => |channel| if (channel.epoch.ms == entry.ms) {
                held.* -= 1;
            },
            else => {},
        };
        reportEvent(progress.console, event);
    }
    if (progress.before_replan) |held| {
        if (held == 0) warnNoChannel(progress.console, progress.scenario, entry);
        progress.before_replan = null;
    }
    if (status.epoch.ms / progress_every_epochs != block.epoch_first.ms / progress_every_epochs) progress.console.info("{d} / {d} ms generated", .{ status.epoch.ms, engine.info().span.epochs });
}

fn printSummary(console: Console, info: engine_run.Info, status: engine_run.Status, path: []const u8, bytes_on_file: u64, seconds: f64) void {
    const mib = cli_files.mib(bytes_on_file);
    console.info("Samples written: {f}, {d} epochs, {f} MiB", .{ Escaped{ .text = path }, bytes_on_file / info.bytes_per_epoch, Number{ .value = mib } });
    const components: u64 = (status.epoch.ms - status.entry_epoch.ms) * info.samples_per_epoch * 2;
    if (components > 0) {
        const clipped = @as(f64, @floatFromInt(status.total_clipped)) / @as(f64, @floatFromInt(components)) * 100.0;
        console.info("Clipped: {d} of {d} components, {f}%", .{ status.total_clipped, components, Number{ .value = clipped } });
    }
    switch (status.gain) {
        .adaptive => |gain| console.info("AGC gain at the end: {f}", .{Number{ .value = gain }}),
        .constant => {},
    }
    console.info("Generated in {f} s, {f} MiB/s", .{ Number{ .value = seconds }, Number{ .value = if (seconds > 0) mib / seconds else 0.0 } });
    console.flush();
}

fn reportEvent(console: Console, event: Event) void {
    switch (event) {
        .agc => |adjustment| console.warn("AGC gain {s} to {f} at {d} ms: {f}% clipped", .{ if (adjustment.reduced) "reduced" else "increased", Number{ .value = adjustment.gain }, adjustment.epoch.ms, Number{ .value = adjustment.clip_rate * 100.0 } }),
        .channel_added => |channel| console.info("Channel {f} added at {d} ms", .{ channel.key, channel.epoch.ms }),
        .channel_removed => |channel| console.info("Channel {f} removed at {d} ms", .{ channel.key, channel.epoch.ms }),
        .ephemeris_switched => |event_data| console.info("Ephemeris of {f} switched at {d} ms", .{ event_data.sat, event_data.epoch.ms }),
        .command_applied => {},
    }
}

fn makeDumpDir(io: Io, dir: []const u8, console: Console) CliError!void {
    Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        cli_files.cannotWrite(console, dir, err);
        return error.Reported;
    };
}

fn writeScenarioDump(arena: std.mem.Allocator, io: Io, dir: []const u8, bundle: *const PreparedBundle, console: Console) CliError!void {
    var text: Io.Writer.Allocating = .init(arena);
    output_dump.writeScenario(&text.writer, bundle) catch return error.OutOfMemory;
    const path = try Io.Dir.path.join(arena, &.{ dir, "scenario.txt" });
    try cli_files.writeFile(io, path, text.written(), console);
    console.info("Scenario dump written: {f}", .{Escaped{ .text = path }});
}

fn writeTag(arena: std.mem.Allocator, io: Io, samples: Samples, first: GpsTime, output_path: []const u8, console: Console) CliError!void {
    var buffer: [output_tag.max_len]u8 = undefined;
    const text = output_tag.text(&buffer, samples, first) orelse {
        console.warn("The .tag format has no {s} format: no tag file written", .{samples.format.name()});
        return;
    };
    const path = try arena.print("{s}.tag", .{output_path});
    try cli_files.writeFile(io, path, text, console);
    console.info("Tag written: {f}", .{Escaped{ .text = path }});
}
