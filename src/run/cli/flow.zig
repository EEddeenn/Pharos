const std = @import("std");
const Io = std.Io;
const pharos_run = @import("pharos_run");
const bundle = pharos_run.bundle;
const Bundle = bundle.Bundle;
const Samples = bundle.scenario.Samples;
const GpsTime = pharos_run.core.time.GpsTime;
const Epoch = pharos_run.core.time.Epoch;
const engine = pharos_run.engine;
const Run = engine.run.Run;
const cli = pharos_run.cli;
const Console = cli.Console;
const Escaped = pharos_run.core.diagnostics.Escaped;
const Number = cli.Number;
const Args = @import("args.zig").Args;

const progress_every_epochs = 10_000;

pub fn generate(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b = cli.loadBundle(io, gpa, arena.allocator(), args.input, console) orelse return 1;
    const samples = b.scenario.samples orelse {
        console.fail("The bundle has no samples block: nothing to generate", .{});
        return 1;
    };
    const dump_dir = if (args.dry_run) null else args.dump;
    var dumps: DumpFiles = .{};
    defer _ = dumps.close(io, console);
    if (dump_dir) |dir| {
        if (!makeDumpDir(io, dir, console) or !dumps.open(arena.allocator(), io, dir, console)) return 1;
    }
    var options = args.options;
    options.dumps = dumps.writers();
    const run = Run.create(gpa, &b, samples, options) catch |e| {
        reportInitError(console, e);
        return 1;
    };
    defer run.destroy();
    if (args.seek) |target| run.seek(target) catch |e| {
        reportSeekError(console, run, target, e);
        return 1;
    };
    if (args.dry_run) {
        _ = report(console, &b, run, args);
        return 0;
    }
    const output_path = args.output orelse cli.withExtension(arena.allocator(), args.input, "bin") catch return cli.outOfMemory(console);
    if (dump_dir) |dir| {
        if (!writeScenarioDump(arena.allocator(), io, dir, &b, console)) return 1;
    }
    if (args.tag and !writeTag(arena.allocator(), io, run.info.samples, run.entryTime(), output_path, console)) return 1;
    var progress: Progress = .{ .console = console, .before_replan = report(console, &b, run, args) };
    return writeSamples(gpa, io, run, &dumps, output_path, &progress);
}

fn report(console: Console, b: *const Bundle, run: *Run, args: Args) ?usize {
    cli.reportTrajectory(console, &b.trajectory, b.scenario.trajectory_file);
    cli.reportSpan(console, run.info.span, b.plan.leap);
    cli.reportNavigation(console, b);
    cli.reportCoverage(console, b);
    cli.reportServices(console, &b.scenario);
    cli.printIonosphere(console, run.ionosphere());
    const samples = run.info.samples;
    console.info("Sampling: {s} at {d} MHz, centre {d} MHz: {d} samples, {d} bytes per epoch", .{ samples.format.name(), samples.sample_rate.mhz(), samples.center.mhz(), run.info.samples_per_epoch, run.info.bytes_per_epoch });
    const noise = engine.run.NoiseMode.words.get(run.options.noise);
    switch (run.gain) {
        .adaptive => console.info("Options: workers {d}, seed {d}, noise {s}, gain adaptive", .{ run.info.workers, run.options.seed, noise }),
        .constant => |constant| console.info("Options: workers {d}, seed {d}, noise {s}, gain constant {f} dB", .{ run.info.workers, run.options.seed, noise, Number{ .value = constant.level.db } }),
    }
    if (args.seek != null) {
        console.info("Starting at epoch {d} of {d}, {f}", .{ run.entryEpoch().ms, run.info.span.epochs, run.entryTime().printed(null) });
    }
    return reportChannels(console, run);
}

fn reportChannels(console: Console, run: *Run) ?usize {
    var held: usize = 0;
    while (run.nextEvent()) |ev| {
        if (ev == .channel_added) held += 1;
        reportEvent(console, ev);
    }
    const entry = run.entryEpoch();
    if (entry.ms != 0 and entry.ms % pharos_run.stage.channels.replan_epochs == 0) return held;
    if (held == 0) warnNoChannel(console, entry);
    return null;
}

fn warnNoChannel(console: Console, entry: Epoch) void {
    console.warn("No channel at epoch {d}: no satellite of a listed signal has a record there and stands above the elevation mask; the samples carry noise alone", .{entry.ms});
}

const Progress = struct {
    console: Console,
    before_replan: ?usize,
};

fn writeSamples(gpa: std.mem.Allocator, io: Io, run: *Run, dumps: *DumpFiles, output_path: []const u8, progress: *Progress) u8 {
    const console = progress.console;
    console.flush();
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    const written = pharos_run.io.sink.writeRun(gpa, io, output_path, run, progress, reportBlock) catch |e| {
        if (e == error.OutOfMemory) return cli.outOfMemory(console);
        cli.cannotWrite(console, output_path, e);
        return 1;
    };
    const elapsed_ns: f64 = @floatFromInt(t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
    if (written.failed) |e| reportStop(console, run, e);
    if (written.write_failed) |e| cli.cannotWrite(console, output_path, e);
    printSummary(console, run, output_path, written.bytes_on_file, elapsed_ns / 1e9);
    if (!dumps.close(io, console)) return 1;
    return if (written.failed != null or written.write_failed != null) 1 else 0;
}

fn reportSeekError(console: Console, run: *const Run, target: Epoch, e: engine.run.SeekError) void {
    switch (e) {
        error.EpochOutOfRange => console.fail("--seek must be at most {d}, got {d}", .{ run.info.span.epochs, target.ms }),
        error.AdaptiveGain => console.fail("--seek needs --gain: {s}", .{engine.run.reason(e)}),
        error.CommandsApplied => unreachable,
        else => |failure| reportStop(console, run, failure),
    }
}

fn reportStop(console: Console, run: *const Run, e: engine.run.PullError) void {
    console.fail("Epoch {d} of {d} could not be generated: {s}", .{ run.epoch.ms, run.info.span.epochs, engine.run.reason(e) });
}

fn reportBlock(progress: *Progress, run: *Run, block: engine.run.Block) void {
    const entry = run.entryEpoch();
    while (run.nextEvent()) |ev| {
        if (progress.before_replan) |*held| switch (ev) {
            .channel_added => |c| if (c.epoch.ms == entry.ms) {
                held.* += 1;
            },
            .channel_removed => |c| if (c.epoch.ms == entry.ms) {
                held.* -= 1;
            },
            else => {},
        };
        reportEvent(progress.console, ev);
    }
    if (progress.before_replan) |held| {
        if (held == 0) warnNoChannel(progress.console, entry);
        progress.before_replan = null;
    }
    if (run.epoch.ms / progress_every_epochs != block.epoch_first.ms / progress_every_epochs) progress.console.info("{d} / {d} ms generated", .{ run.epoch.ms, run.info.span.epochs });
}

fn printSummary(console: Console, run: *const Run, path: []const u8, bytes_on_file: u64, seconds: f64) void {
    const mib = cli.mib(bytes_on_file);
    console.info("Samples written: {f}, {d} epochs, {f} MiB", .{ Escaped{ .text = path }, bytes_on_file / run.info.bytes_per_epoch, Number{ .value = mib } });
    const components: u64 = (run.epoch.ms - run.entryEpoch().ms) * run.info.samples_per_epoch * 2;
    if (components > 0) {
        const clipped = @as(f64, @floatFromInt(run.total_clipped)) / @as(f64, @floatFromInt(components)) * 100.0;
        console.info("Clipped: {d} of {d} components, {f}%", .{ run.total_clipped, components, Number{ .value = clipped } });
    }
    switch (run.gain) {
        .adaptive => |agc| console.info("AGC gain at the end: {f}", .{Number{ .value = agc.gain }}),
        .constant => {},
    }
    console.info("Generated in {f} s, {f} MiB/s", .{ Number{ .value = seconds }, Number{ .value = if (seconds > 0) mib / seconds else 0.0 } });
    console.flush();
}

const DumpFiles = struct {
    const names = [_][]const u8{ "rows.txt", "plan.txt", "params.txt" };
    files: [names.len]cli.FileWriter = undefined,
    paths: [names.len][]const u8 = undefined,
    opened: [names.len]bool = @splat(false),

    fn open(self: *DumpFiles, arena: std.mem.Allocator, io: Io, dir: []const u8, console: Console) bool {
        for (names, &self.files, &self.paths, &self.opened) |name, *file, *path, *opened| {
            path.* = Io.Dir.path.join(arena, &.{ dir, name }) catch {
                _ = cli.outOfMemory(console);
                return false;
            };
            file.open(io, path.*) catch |e| {
                cli.cannotWrite(console, path.*, e);
                return false;
            };
            opened.* = true;
        }
        return true;
    }

    fn writers(self: *DumpFiles) engine.run.Dumps {
        if (!self.opened[0]) return .{};
        return .{ .rows = self.files[0].interface(), .plan = self.files[1].interface(), .params = self.files[2].interface() };
    }

    fn close(self: *DumpFiles, io: Io, console: Console) bool {
        var ok = true;
        for (&self.files, self.paths, &self.opened) |*file, path, *opened| if (opened.*) {
            file.finish(io) catch |e| {
                cli.cannotWrite(console, path, e);
                ok = false;
            };
            opened.* = false;
        };
        return ok;
    }
};

fn reportInitError(console: Console, e: engine.run.CreateError) void {
    console.fail("Cannot create the run: {s}", .{engine.run.reason(e)});
}

fn reportEvent(console: Console, ev: engine.events.Event) void {
    switch (ev) {
        .agc => |a| console.warn("AGC gain {s} to {f} at {d} ms: {f}% clipped", .{ if (a.reduced) "reduced" else "increased", Number{ .value = a.gain }, a.epoch.ms, Number{ .value = a.clip_rate * 100.0 } }),
        .channel_added => |c| console.info("Channel {f} added at {d} ms", .{ c.key, c.epoch.ms }),
        .channel_removed => |c| console.info("Channel {f} removed at {d} ms", .{ c.key, c.epoch.ms }),
        .ephemeris_switched => |e| console.info("Ephemeris of {f} switched at {d} ms", .{ e.sat, e.epoch.ms }),
        .command_applied => {},
    }
}

fn makeDumpDir(io: Io, dir: []const u8, console: Console) bool {
    Io.Dir.cwd().createDirPath(io, dir) catch |e| {
        cli.cannotWrite(console, dir, e);
        return false;
    };
    return true;
}

fn writeScenarioDump(arena: std.mem.Allocator, io: Io, dir: []const u8, b: *const Bundle, console: Console) bool {
    var text: Io.Writer.Allocating = .init(arena);
    pharos_run.io.dump.writeScenario(&text.writer, b) catch {
        _ = cli.outOfMemory(console);
        return false;
    };
    const path = Io.Dir.path.join(arena, &.{ dir, "scenario.txt" }) catch {
        _ = cli.outOfMemory(console);
        return false;
    };
    if (!cli.writeFile(io, path, text.written(), console)) return false;
    console.info("Scenario dump written: {f}", .{Escaped{ .text = path }});
    return true;
}

fn writeTag(arena: std.mem.Allocator, io: Io, samples: Samples, first: GpsTime, output_path: []const u8, console: Console) bool {
    var buffer: [pharos_run.io.tag.max_len]u8 = undefined;
    const text = pharos_run.io.tag.text(&buffer, samples, first) orelse {
        console.warn("The .tag format has no {s} format: no tag file written", .{samples.format.name()});
        return true;
    };
    const path = arena.print("{s}.tag", .{output_path}) catch {
        _ = cli.outOfMemory(console);
        return false;
    };
    if (!cli.writeFile(io, path, text, console)) return false;
    console.info("Tag written: {f}", .{Escaped{ .text = path }});
    return true;
}
