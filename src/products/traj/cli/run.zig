const std = @import("std");
const pht_read = @import("pht/read");
const pht_write = @import("pht/write");
const construction_static = @import("products/traj/construction/static");
const diagnostics = @import("base/diagnostics");
const cli_console = @import("interface/cli/console");
const cli_files = @import("interface/cli/files");
const cli_diagnostics = @import("interface/cli/diagnostics");
const cli_arguments = @import("interface/cli/arguments");
const cli_reports = @import("interface/cli/reports");
const coordinates = @import("domain/earth/coordinates");
const geoid = @import("domain/earth/geoid/model");
const pipeline = @import("products/traj/pipeline");
const stats = @import("products/traj/output/stats");
const kml = @import("products/traj/output/kml");
const trajectory = @import("domain/trajectory/trajectory");
const args_mod = @import("products/traj/cli/args");

const Io = std.Io;
const Trajectory = trajectory.Trajectory;
const Diagnostics = diagnostics.Diagnostics;
const Escaped = diagnostics.Escaped;
const Console = cli_console.Console;
const Number = @import("base/text/number").Number;
const CliError = cli_console.Error;
const Args = args_mod.Args;

const latitude_range = std.fmt.comptimePrint("from {d} to {d} degrees", .{ construction_static.latitude_range.min, construction_static.latitude_range.max });
const longitude_range = std.fmt.comptimePrint("from {d} to {d} degrees", .{ construction_static.longitude_range.min, construction_static.longitude_range.max });
const position_range = std.fmt.comptimePrint("from {d} to {d} m from the geocentre", .{ trajectory.min_radius_m, trajectory.max_radius_m });
const duration_range = std.fmt.comptimePrint("from {d} to {d} seconds", .{ construction_static.duration_range.min, construction_static.duration_range.max });

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) CliError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (args) {
        .build => |a| build(gpa, arena, io, a, console),
        .static => |a| static(arena, io, a, console),
        .info => |input| info(arena, io, input, console),
        .check => |input| check(arena, io, input, console),
        .@"export" => |a| exportKml(arena, io, a, console),
    };
}

fn build(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, args: args_mod.Build, console: Console) CliError!void {
    const text = try cli_files.readFile(io, arena, args.input, cli_files.max_input_bytes, console);
    var diags: Diagnostics = .{ .arena = arena, .source = args.input };
    const built = pipeline.build(gpa, arena, text, &diags) catch |err| return cli_diagnostics.reportFailure(console, &diags, err);
    cli_diagnostics.printDiagnostics(console, &diags);
    if (built.refusal()) |why| {
        console.fail("The path {s}: no PHT is written", .{why});
        return error.Reported;
    }
    var traj = built.path.trajectory;
    if (args.name) |name| traj.name = name;
    return save(io, arena, traj, args.output orelse try cli_files.withExtension(arena, args.input, "pht"), console);
}

fn static(arena: std.mem.Allocator, io: Io, args: args_mod.Static, console: Console) CliError!void {
    const traj = construction_static.build(arena, args.name orelse "", args.at.value, args.duration_s.value) catch |e| {
        const at = args.at.found;
        const duration = args.duration_s.found;
        const refusal: cli_arguments.Refusal = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LatitudeOutOfRange => .{ .outside = .{ .option = try arena.print("{s}'s latitude", .{at.spelling}), .range = latitude_range, .got = part(at.value, 0) } },
            error.LongitudeOutOfRange => .{ .outside = .{ .option = try arena.print("{s}'s longitude", .{at.spelling}), .range = longitude_range, .got = part(at.value, 1) } },
            error.PositionOutOfRange => .{ .outside = .{ .option = try arena.print("{s}'s position", .{at.spelling}), .range = position_range, .got = at.value } },
            error.DurationOutOfRange => .{ .outside = .{ .option = duration.spelling, .range = duration_range, .got = duration.value } },
        };
        console.fail("{f}", .{refusal});
        return error.Reported;
    };
    return save(io, arena, traj, args.output, console);
}

/// One number of an option's comma-separated three, as it was given.
fn part(text: []const u8, index: usize) []const u8 {
    var parts = std.mem.splitScalar(u8, text, ',');
    for (0..index) |_| _ = parts.next();
    return parts.next().?;
}

fn info(arena: std.mem.Allocator, io: Io, input: []const u8, console: Console) CliError!void {
    const traj = try load(io, arena, input, console);
    cli_reports.reportTrajectory(console, &traj, input);
    printPosition(console, "Start", traj.knots[0].pos);
    printPosition(console, "End", traj.knots[traj.knots.len - 1].pos);
}

fn check(arena: std.mem.Allocator, io: Io, input: []const u8, console: Console) CliError!void {
    const traj = try load(io, arena, input, console);
    cli_reports.reportTrajectory(console, &traj, input);
    const st = try stats.of(arena, traj);
    console.info("Speed up to {f} m/s, acceleration up to {f} m/s^2, jerk up to {f} m/s^3", .{ Number{ .value = st.max_speed_mps }, Number{ .value = st.max_acceleration_mps2 }, Number{ .value = st.max_jerk_mps3 } });
    console.info("Altitude from {f} to {f} m", .{ Number{ .value = st.min_altitude_m }, Number{ .value = st.max_altitude_m } });
    if (st.largest_acceleration_step_s) |at| {
        console.info("Acceleration steps: {d}, the largest {f} m/s^2 at {f} s", .{ st.acceleration_steps, Number{ .value = st.largest_acceleration_step_mps2 }, Number{ .value = at } });
    }
    if (st.largest_velocity_step_s) |at| {
        console.info("Velocity steps: {d}, the largest {f} m/s at {f} s", .{ st.velocity_steps, Number{ .value = st.largest_velocity_step_mps }, Number{ .value = at } });
    }
}

fn exportKml(arena: std.mem.Allocator, io: Io, args: args_mod.Export, console: Console) CliError!void {
    const traj = try load(io, arena, args.input, console);
    const path = args.output orelse try cli_files.withExtension(arena, args.input, "kml");
    var text: Io.Writer.Allocating = .init(arena);
    kml.write(&text.writer, traj) catch return error.OutOfMemory;
    try cli_files.writeFile(io, path, text.written(), console);
    console.info("KML written: {f}", .{Escaped{ .text = path }});
}

fn printPosition(console: Console, label: []const u8, pos: coordinates.Ecef) void {
    const p = coordinates.ecefToLla(pos);
    console.info("{s}: latitude {d:.9}, longitude {d:.9}, altitude {d:.4} m", .{ label, p.latDeg(), p.lonDeg(), geoid.altitude(p) });
}

fn load(io: Io, arena: std.mem.Allocator, path: []const u8, console: Console) CliError!Trajectory {
    const bytes = try cli_files.readFile(io, arena, path, cli_files.max_input_bytes, console);
    var diags: Diagnostics = .{ .arena = arena };
    return pht_read.read(arena, bytes, diags.forSource(path)) catch |err| cli_diagnostics.reportFailure(console, &diags, err);
}

fn save(io: Io, arena: std.mem.Allocator, traj: Trajectory, path: []const u8, console: Console) CliError!void {
    var encoded: Io.Writer.Allocating = .init(arena);
    pht_write.write(&encoded.writer, traj) catch return error.OutOfMemory;
    cli_reports.reportTrajectory(console, &traj, path);
    try cli_files.writeFile(io, path, encoded.written(), console);
    console.info("Trajectory written: {f}", .{Escaped{ .text = path }});
}
