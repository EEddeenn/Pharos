const std = @import("std");
const Io = std.Io;
const pharos_traj = @import("pharos_traj");
const core = pharos_traj.core;
const coord = core.coord;
const trajectory = pharos_traj.trajectory;
const Trajectory = trajectory.Trajectory;
const Diagnostics = pharos_traj.core.diagnostics.Diagnostics;
const Escaped = pharos_traj.core.diagnostics.Escaped;
const cli = pharos_traj.cli;
const Console = cli.Console;
const Number = cli.Number;
const args_mod = @import("args.zig");
const Args = args_mod.Args;

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, console: Console) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const status = switch (args) {
        .build => |a| build(gpa, arena, io, a, console),
        .static => |a| static(arena, io, a, console),
        .info => |input| info(arena, io, input, console),
        .check => |input| check(arena, io, input, console),
        .@"export" => |a| exportKml(arena, io, a, console),
    } catch return cli.outOfMemory(console);
    console.flush();
    return status;
}

const Error = error{OutOfMemory};

fn build(allocator: std.mem.Allocator, arena: std.mem.Allocator, io: Io, args: args_mod.Build, console: Console) Error!u8 {
    const text = try cli.readFile(io, arena, args.input, cli.max_input_bytes, console) orelse return 1;
    var diags: Diagnostics = .{ .arena = arena, .source = args.input };
    const built = pharos_traj.source.build(allocator, arena, text, &diags) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        cli.printDiagnostics(console, &diags);
        return 1;
    };
    cli.printDiagnostics(console, &diags);
    if (built.refusal()) |why| {
        console.fail("The path {s}: no PHT is written", .{why});
        return 1;
    }
    var traj = built.trajectory;
    if (args.name) |name| traj.name = name;
    return save(io, arena, traj, args.output orelse try cli.withExtension(arena, args.input, "pht"), console);
}

const latitude_range = std.fmt.comptimePrint("from {d} to {d} degrees", .{ pharos_traj.static.latitude_range.min, pharos_traj.static.latitude_range.max });
const longitude_range = std.fmt.comptimePrint("from {d} to {d} degrees", .{ pharos_traj.static.longitude_range.min, pharos_traj.static.longitude_range.max });
const position_range = std.fmt.comptimePrint("from {d} to {d} m from the geocentre", .{ trajectory.min_radius_m, trajectory.max_radius_m });
const duration_range = std.fmt.comptimePrint("from {d} to {d} seconds", .{ pharos_traj.static.duration_range.min, pharos_traj.static.duration_range.max });

fn static(arena: std.mem.Allocator, io: Io, args: args_mod.Static, console: Console) Error!u8 {
    const traj = pharos_traj.static.build(arena, args.name orelse "", args.at.value, args.duration_s.value) catch |e| {
        const at = args.at.found;
        const duration = args.duration_s.found;
        const refusal: cli.Refusal = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LatitudeOutOfRange => .{ .outside = .{ .option = try arena.print("{s}'s latitude", .{at.spelling}), .range = latitude_range, .got = part(at.value, 0) } },
            error.LongitudeOutOfRange => .{ .outside = .{ .option = try arena.print("{s}'s longitude", .{at.spelling}), .range = longitude_range, .got = part(at.value, 1) } },
            error.PositionOutOfRange => .{ .outside = .{ .option = try arena.print("{s}'s position", .{at.spelling}), .range = position_range, .got = at.value } },
            error.DurationOutOfRange => .{ .outside = .{ .option = duration.spelling, .range = duration_range, .got = duration.value } },
        };
        console.fail("{f}", .{refusal});
        return 1;
    };
    return save(io, arena, traj, args.output, console);
}

/// One number of an option's comma-separated three, as it was given.
fn part(text: []const u8, index: usize) []const u8 {
    var parts = std.mem.splitScalar(u8, text, ',');
    for (0..index) |_| _ = parts.next();
    return parts.next().?;
}

fn info(arena: std.mem.Allocator, io: Io, input: []const u8, console: Console) Error!u8 {
    const traj = try load(io, arena, input, console) orelse return 1;
    cli.reportTrajectory(console, &traj, input);
    printPosition(console, "Start", traj.knots[0].pos);
    printPosition(console, "End", traj.knots[traj.knots.len - 1].pos);
    return 0;
}

fn check(arena: std.mem.Allocator, io: Io, input: []const u8, console: Console) Error!u8 {
    const traj = try load(io, arena, input, console) orelse return 1;
    cli.reportTrajectory(console, &traj, input);
    const st = try pharos_traj.stats.of(arena, traj);
    console.info("Speed up to {f} m/s, acceleration up to {f} m/s^2, jerk up to {f} m/s^3", .{ Number{ .value = st.max_speed_mps }, Number{ .value = st.max_acceleration_mps2 }, Number{ .value = st.max_jerk_mps3 } });
    console.info("Altitude from {f} to {f} m", .{ Number{ .value = st.min_altitude_m }, Number{ .value = st.max_altitude_m } });
    if (st.largest_acceleration_step_s) |at| {
        console.info("Acceleration steps: {d}, the largest {f} m/s^2 at {f} s", .{ st.acceleration_steps, Number{ .value = st.largest_acceleration_step_mps2 }, Number{ .value = at } });
    }
    if (st.largest_velocity_step_s) |at| {
        console.info("Velocity steps: {d}, the largest {f} m/s at {f} s", .{ st.velocity_steps, Number{ .value = st.largest_velocity_step_mps }, Number{ .value = at } });
    }
    return 0;
}

fn exportKml(arena: std.mem.Allocator, io: Io, args: args_mod.Export, console: Console) Error!u8 {
    const traj = try load(io, arena, args.input, console) orelse return 1;
    const path = args.output orelse try cli.withExtension(arena, args.input, "kml");
    var text: Io.Writer.Allocating = .init(arena);
    pharos_traj.kml.write(&text.writer, traj) catch return error.OutOfMemory;
    if (!cli.writeFile(io, path, text.written(), console)) return 1;
    console.info("KML written: {f}", .{Escaped{ .text = path }});
    return 0;
}

fn printPosition(console: Console, label: []const u8, pos: coord.Ecef) void {
    const p = coord.ecefToLla(pos);
    console.info("{s}: latitude {d:.9}, longitude {d:.9}, altitude {d:.4} m", .{ label, p.latDeg(), p.lonDeg(), core.geoid.altitude(p) });
}

fn load(io: Io, arena: std.mem.Allocator, path: []const u8, console: Console) Error!?Trajectory {
    const bytes = try cli.readFile(io, arena, path, trajectory.pht.max_bytes, console) orelse return null;
    var diags = Diagnostics.init(arena);
    return trajectory.pht.read(arena, bytes, diags.forSource(path)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        cli.printDiagnostics(console, &diags);
        return null;
    };
}

fn save(io: Io, arena: std.mem.Allocator, traj: Trajectory, path: []const u8, console: Console) Error!u8 {
    var text: Io.Writer.Allocating = .init(arena);
    trajectory.pht.write(&text.writer, traj) catch |e| switch (e) {
        error.TooLarge => {
            console.fail("The path takes more than the {d} bytes a PHT holds: no PHT is written", .{trajectory.pht.max_bytes});
            return 1;
        },
        error.WriteFailed => return error.OutOfMemory,
    };
    cli.reportTrajectory(console, &traj, path);
    if (!cli.writeFile(io, path, text.written(), console)) return 1;
    console.info("Trajectory written: {f}", .{Escaped{ .text = path }});
    return 0;
}
