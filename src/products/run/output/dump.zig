const std = @import("std");
const gnss_types = @import("domain/gnss_types");

const PreparedBundle = @import("phb/prepared").PreparedBundle;
const hex = @import("base/text/hex").double;

pub fn writeScenario(w: *std.Io.Writer, b: *const PreparedBundle) std.Io.Writer.Error!void {
    const s = &b.scenario.config;
    const names = &b.display.names;
    const u = s.start.toUtc(b.scenario.flight_plan.leap);
    const traj = &b.scenario.trajectory;
    const k0 = traj.knots[0];
    try w.print(
        \\time.year = {d}
        \\time.month = {d}
        \\time.day = {d}
        \\time.hour = {d}
        \\time.minute = {d}
        \\time.second = {f}
        \\name = {s}
        \\trajectory.file = {s}
        \\trajectory.knots = {d}
        \\trajectory.duration = {f}
        \\trajectory.start.x = {f}
        \\trajectory.start.y = {f}
        \\trajectory.start.z = {f}
        \\run.epochs = {d}
        \\nav_files = {d}
        \\
    , .{ u.year, u.month, u.day, u.hour, u.minute, hex(u.second), names.name, names.trajectory_file, traj.knots.len, hex(traj.duration()), hex(k0.pos.x), hex(k0.pos.y), hex(k0.pos.z), b.scenario.epochs(), names.nav_files.len });
    for (names.nav_files, 0..) |f, i| try w.print("nav_file[{d}] = {s}\n", .{ i, f.path });
    for (gnss_types.System.all) |system| {
        const name = @tagName(system);
        try w.print("mask.{0s} = 0x{1x:0>16}\nsignals.{0s} =", .{ name, s.mask_out.get(system).bits });
        var it = s.signals.iterator();
        while (it.next()) |signal| {
            if (signal.system() == system) try w.print(" {s}", .{signal.name()});
        }
        try w.writeAll("\n");
    }
    try w.print(
        \\elevation_mask = {f}
        \\samples.format = {d}
        \\samples.sample_rate_hz = {d}
        \\samples.center_hz = {d}
        \\observation.interval_ms = {d}
        \\position.interval_ms = {d}
        \\position.format = {d}
        \\power.noise_floor = {f}
        \\power.init_cn0 = {f}
        \\power.elevation_fade = {d}
        \\power.entries = {d}
        \\
    , .{
        hex(s.elevation_mask_rad),
        if (s.samples) |x| @backingInt(x.format) else 0,
        if (s.samples) |x| x.sample_rate.hz() else 0,
        if (s.samples) |x| x.center.hz else 0,
        if (s.observation) |x| x.interval_ms else 0,
        if (s.position) |x| x.interval_ms else 0,
        if (s.position) |x| @backingInt(x.format) else 0,
        hex(s.power.noise_floor_dbm_hz),
        hex(s.power.init_cn0_dbhz),
        @intFromBool(s.power.elevation_fade),
        s.power.schedule.len,
    });
    for (s.power.schedule, 0..) |e, i| {
        const svid = switch (e.target) {
            .whole => 0,
            .sat => |sat| sat.prn(),
        };
        try w.print(
            \\power[{0d}].system = {1d}
            \\power[{0d}].svid = {2d}
            \\power[{0d}].epoch = {3d}
            \\power[{0d}].unit = {4d}
            \\power[{0d}].value = {5f}
            \\
        , .{ i, @backingInt(e.target.system()), svid, e.at_epoch, if (e.level) |l| @backingInt(l.unit) else 3, hex(if (e.level) |l| l.value else 0) });
    }
}
