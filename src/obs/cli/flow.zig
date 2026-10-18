const std = @import("std");
const Io = std.Io;
const pharos_obs = @import("pharos_obs");
const bundle = pharos_obs.bundle;
const Bundle = bundle.Bundle;
const File = pharos_obs.output.File;
const Output = pharos_obs.output.Output;
const Created = pharos_obs.output.Created;
const cli = pharos_obs.cli;
const Console = cli.Console;
const Escaped = pharos_obs.core.diagnostics.Escaped;
const Args = @import("args.zig").Args;

pub fn write(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const b = cli.loadBundle(io, gpa, arena.allocator(), args.input, console) orelse return 1;
    const s = &b.scenario;
    if (s.observation == null and s.position == null) {
        console.fail("The bundle declares no observation or position file: pharos-run generates its samples", .{});
        return 1;
    }
    if (s.observation == null) {
        if (args.observation != null) warnIgnored(console, .observation, "--observation");
        if (args.created != null) warnIgnored(console, .observation, "--created");
    }
    if (s.position == null and args.position != null) warnIgnored(console, .position, "--position");
    const created = args.created orelse readClock(io, console) orelse return 1;
    cli.reportTrajectory(console, &b.trajectory, s.trajectory_file);
    cli.reportNavigation(console, &b);
    cli.reportCoverage(console, &b);
    var status: u8 = 0;
    if (s.observation != null) {
        const path = args.observation orelse cli.withExtension(arena.allocator(), args.input, "obs") catch return cli.outOfMemory(console);
        status |= writeOne(gpa, io, &b, .observation, created, path, args, console);
    }
    if (s.position) |p| {
        const path = args.position orelse cli.withExtension(arena.allocator(), args.input, p.format.extension()) catch return cli.outOfMemory(console);
        status |= writeOne(gpa, io, &b, .position, created, path, args, console);
    }
    return status;
}

fn warnIgnored(console: Console, output: Output, option: []const u8) void {
    console.warn("The bundle declares no {s} file: {s} is ignored", .{ Output.words.get(output), option });
}

fn readClock(io: Io, console: Console) ?Created {
    var read_s: i64 = 0;
    return Created.fromWallClock(io, &read_s) orelse {
        console.fail("The wall clock must read from {d} to {d} s, got {d}", .{ Created.min.unix_s, Created.max.unix_s, read_s });
        return null;
    };
}

fn writeOne(gpa: std.mem.Allocator, io: Io, b: *const Bundle, output: Output, created: Created, path: []const u8, args: Args, console: Console) u8 {
    const file = File.create(gpa, b, output, created) catch |e| {
        reportInitError(console, output, e);
        return 1;
    };
    defer file.destroy();
    if (args.seek) |epoch| file.range(.{ .first = epoch, .end = file.fullRange().end }) catch |e| {
        console.fail("--seek {d} cannot select the {s} file's epochs: {s}", .{ epoch, Output.words.get(output), switch (e) {
            error.Begun => "the file has begun",
            error.EpochOutOfRange => "the range goes beyond the run",
            error.EmptyRange => "no epoch of the run is left from it",
            error.NoEpochs => "the file has no epoch from it on",
        } });
        return 1;
    };
    if (file.ionosphere()) |ionosphere| cli.printIonosphere(console, ionosphere);
    const title = switch (output) {
        .observation => "Observation file",
        .position => "Position file",
    };
    const summary = file.summary();
    const from: From = .{ .ms = if (args.seek != null) summary.first_ms else null };
    if (summary.tracked) |tracked| {
        console.info("{s}: {d} epochs every {d} ms{f}, {d} satellites tracked", .{ title, summary.epochs, summary.interval_ms, from, tracked });
    } else console.info("{s}: {d} epochs every {d} ms{f}", .{ title, summary.epochs, summary.interval_ms, from });
    console.flush();
    if (args.dry_run) return 0;
    var out: cli.FileWriter = undefined;
    out.open(io, path) catch |e| {
        cli.cannotWrite(console, path, e);
        return 1;
    };
    while (true) {
        const batch = file.pull(pharos_obs.output.max_batch_epochs) catch unreachable;
        out.interface().writeAll(batch.bytes) catch break;
        if (batch.end) break;
    }
    out.finish(io) catch |e| {
        cli.cannotWrite(console, path, e);
        return 1;
    };
    console.info("{s} written: {f}", .{ title, Escaped{ .text = path } });
    console.flush();
    return 0;
}

const From = struct {
    ms: ?u64,

    pub fn format(self: From, w: *Io.Writer) Io.Writer.Error!void {
        if (self.ms) |ms| try w.print(" from epoch {d}", .{ms});
    }
};

fn reportInitError(console: Console, output: Output, e: pharos_obs.output.Error) void {
    console.fail("Cannot create the {s} file: {s}", .{ Output.words.get(output), pharos_obs.output.reason(e) });
}
