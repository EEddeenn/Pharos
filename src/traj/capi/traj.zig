const std = @import("std");
const Io = std.Io;
const core = @import("shared").core;
const coord = core.coord;
const shared_trajectory = @import("shared").trajectory;
const Trajectory = shared_trajectory.Trajectory;
const Diagnostics = @import("shared").core.diagnostics.Diagnostics;
const Number = @import("shared").json.node.Number;
const Range = @import("shared").json.table.Range;
const stationary = @import("../static.zig");
const source = @import("../source.zig");
const inspect = @import("../inspect.zig");
const kml = @import("../kml.zig");
const stats = @import("../stats.zig");
const frame = @import("../frame.zig");
const capi = @import("shared").capi;
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

pub const Diag = capi.Diag;

pub const Handle = struct {
    arena: std.heap.ArenaAllocator,
    content: union(enum) { none, loaded: Trajectory, built: source.Result } = .none,
    c_diags: []Diag = &.{},
    pht_bytes: ?[]u8 = null,
    kml_bytes: ?[]u8 = null,
    inspection_bytes: ?[]u8 = null,
    /// The path's statistics, found at the first `info_get`.
    info: ?Info = null,
    err: ErrorBuffer = .{},

    fn trajectory(self: *const Handle) ?Trajectory {
        return switch (self.content) {
            .none => null,
            .loaded => |traj| traj,
            .built => |built| built.trajectory,
        };
    }

    fn refusal(self: *const Handle) ?[]const u8 {
        return switch (self.content) {
            .none, .loaded => null,
            .built => |built| built.refusal(),
        };
    }
};

pub const Info = extern struct {
    velocity_steps: u32 = 0,
    knots: u64 = 0,
    duration_s: f64 = 0,
    max_speed_mps: f64 = 0,
    max_acceleration_mps2: f64 = 0,
    max_jerk_mps3: f64 = 0,
    min_altitude_m: f64 = 0,
    max_altitude_m: f64 = 0,
    acceleration_steps: u32 = 0,
    largest_acceleration_step_mps2: f64 = 0,
    largest_acceleration_step_s: f64 = 0,
    largest_velocity_step_mps: f64 = 0,
    largest_velocity_step_s: f64 = 0,
};

pub const State = extern struct {
    pos: [3]f64 = .{ 0, 0, 0 },
    vel: [3]f64 = .{ 0, 0, 0 },
    acc: [3]f64 = .{ 0, 0, 0 },
    lat_deg: f64 = 0,
    lon_deg: f64 = 0,
    altitude_m: f64 = 0,
    speed_mps: f64 = 0,
    course_deg: f64 = 0,
};

fn create() ?*Handle {
    const h = allocator.create(Handle) catch return null;
    h.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    return h;
}

fn nomemDestroy(h: *Handle) Status {
    pharos_traj_destroy(h);
    return nomem(&common.thread_error);
}

fn finish(h: *Handle, diags: *const Diagnostics, status: Status, out: *?*Handle) Status {
    h.c_diags = capi.diagsOf(h.arena.allocator(), diags.slice()) catch return nomemDestroy(h);
    if (status == .input) if (diags.firstError()) |d| h.err.set("{f}", .{d});
    out.* = h;
    return status;
}

pub fn pharos_traj_build(json: ?[*]const u8, len: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const bytes = (json orelse return .arg)[0..len];
    const h = create() orelse return nomem(&common.thread_error);
    const arena = h.arena.allocator();
    var diags = Diagnostics.init(arena);
    const built = source.build(allocator, arena, bytes, &diags) catch |e| {
        if (e == error.OutOfMemory) return nomemDestroy(h);
        return finish(h, &diags, .input, o);
    };
    h.content = .{ .built = built };
    return finish(h, &diags, if (built.valid) .ok else .input, o);
}

pub fn pharos_traj_read(bytes: ?[*]const u8, len: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const data = (bytes orelse return .arg)[0..len];
    const h = create() orelse return nomem(&common.thread_error);
    const arena = h.arena.allocator();
    var diags = Diagnostics.init(arena);
    // As every other reader of a PHT does.
    if (data.len > shared_trajectory.pht.max_bytes) {
        diags.err(.out_of_range, "", "a PHT must be at most {d} bytes, got {d}", .{ shared_trajectory.pht.max_bytes, data.len }) catch return nomemDestroy(h);
        return finish(h, &diags, .input, o);
    }
    const traj = shared_trajectory.pht.read(arena, data, diags.forSource("")) catch |e| {
        if (e == error.OutOfMemory) return nomemDestroy(h);
        return finish(h, &diags, .input, o);
    };
    h.content = .{ .loaded = traj };
    return finish(h, &diags, .ok, o);
}

pub fn pharos_traj_static(lat_deg: f64, lon_deg: f64, altitude_m: f64, duration_s: f64, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const h = create() orelse return nomem(&common.thread_error);
    const traj = stationary.build(h.arena.allocator(), "", .{ .lla = .{ .lat_deg = lat_deg, .lon_deg = lon_deg, .altitude_m = altitude_m } }, duration_s) catch |e| {
        switch (e) {
            error.OutOfMemory => return nomemDestroy(h),
            error.LatitudeOutOfRange => outside("lat_deg", stationary.latitude_range, lat_deg),
            error.LongitudeOutOfRange => outside("lon_deg", stationary.longitude_range, lon_deg),
            error.PositionOutOfRange => common.thread_error.set("altitude_m must put the receiver {f} m from the geocentre, got {f}", .{ Range{ .min = shared_trajectory.min_radius_m, .max = shared_trajectory.max_radius_m }, Number{ .value = altitude_m } }),
            error.DurationOutOfRange => outside("duration_s", stationary.duration_range, duration_s),
        }
        pharos_traj_destroy(h);
        return .arg;
    };
    h.content = .{ .loaded = traj };
    o.* = h;
    return .ok;
}

fn outside(comptime name: []const u8, range: Range, value: f64) void {
    common.thread_error.set(name ++ " must be {f}, got {f}", .{ range, Number{ .value = value, .outside = range } });
}

pub fn pharos_traj_diag_count(h: ?*const Handle) callconv(.c) usize {
    return if (h) |t| t.c_diags.len else 0;
}

pub fn pharos_traj_diag_get(h: ?*const Handle, index: usize, out: ?*Diag) callconv(.c) Status {
    const t = h orelse return .arg;
    const o = out orelse return .arg;
    if (index >= t.c_diags.len) return .arg;
    o.* = t.c_diags[index];
    return .ok;
}

fn trajectoryOf(h: ?*const Handle) ?Trajectory {
    return (h orelse return null).trajectory();
}

pub fn pharos_traj_has_path(h: ?*const Handle) callconv(.c) c_int {
    return @intFromBool(trajectoryOf(h) != null);
}

pub fn pharos_traj_info_get(h: ?*Handle, out: ?*Info) callconv(.c) Status {
    const t = h orelse return .arg;
    t.err.begin();
    const o = out orelse return .arg;
    const traj = t.trajectory() orelse return noTrajectory(t);
    if (t.info == null) {
        const st = stats.of(allocator, traj) catch return nomem(&t.err);
        t.info = .{
            .velocity_steps = std.math.lossyCast(u32, st.velocity_steps),
            .knots = st.knots,
            .duration_s = st.duration_s,
            .max_speed_mps = st.max_speed_mps,
            .max_acceleration_mps2 = st.max_acceleration_mps2,
            .max_jerk_mps3 = st.max_jerk_mps3,
            .min_altitude_m = st.min_altitude_m,
            .max_altitude_m = st.max_altitude_m,
            .acceleration_steps = std.math.lossyCast(u32, st.acceleration_steps),
            .largest_acceleration_step_mps2 = st.largest_acceleration_step_mps2,
            .largest_acceleration_step_s = st.largest_acceleration_step_s orelse 0,
            .largest_velocity_step_mps = st.largest_velocity_step_mps,
            .largest_velocity_step_s = st.largest_velocity_step_s orelse 0,
        };
    }
    o.* = t.info.?;
    return .ok;
}

pub fn pharos_traj_state_get(h: ?*const Handle, t_s: f64, out: ?*State) callconv(.c) Status {
    const traj = trajectoryOf(h) orelse return .arg;
    const o = out orelse return .arg;
    const reach = shared_trajectory.max_duration_s;
    if (!(t_s >= -reach and t_s <= traj.duration() + reach)) return .arg;
    const s = traj.at(t_s);
    const p = coord.ecefToLla(s.pos);
    // The course as inspect reads it: none below a millimetre a second, in [0, 360).
    const reading = frame.Reading.of(s, .ellipsoid, null);
    const state: State = .{
        .pos = s.pos.toArray(),
        .vel = s.vel.toArray(),
        .acc = s.acc.toArray(),
        .lat_deg = p.latDeg(),
        .lon_deg = p.lonDeg(),
        .altitude_m = core.geoid.altitude(p),
        .speed_mps = s.vel.norm(),
        .course_deg = reading.course_deg orelse std.math.nan(f64),
    };
    o.* = state;
    return .ok;
}

pub fn pharos_traj_bytes(h: ?*Handle, out: ?*?[*]const u8, len: ?*usize) callconv(.c) Status {
    return serialized(h, .pht, out, len);
}

pub fn pharos_traj_kml(h: ?*Handle, out: ?*?[*]const u8, len: ?*usize) callconv(.c) Status {
    return serialized(h, .kml, out, len);
}

pub fn pharos_traj_inspect(h: ?*Handle, sample_count: usize, out: ?*?[*]const u8, len: ?*usize) callconv(.c) Status {
    const t = h orelse return .arg;
    t.err.begin();
    const dst = out orelse return .arg;
    const count = len orelse return .arg;
    dst.* = null;
    count.* = 0;
    if (sample_count < 2) {
        t.err.set("sample_count must be at least 2, got {d}", .{sample_count});
        return .arg;
    }
    const built = switch (t.content) {
        .none => return noTrajectory(t),
        .loaded => return .ok,
        .built => |built| built,
    };
    // The text before is freed first; the next is counted and then written into a block of its size: in a WebAssembly
    // instance every block a growing buffer leaves stays taken.
    if (t.inspection_bytes) |previous| allocator.free(previous);
    t.inspection_bytes = null;
    const lengths = inspect.Lengths.of(allocator, built, sample_count) catch return nomem(&t.err);
    defer lengths.deinit(allocator);
    // Neither write fails: the first only counts, and the block holds what it counted.
    var buffer: [4096]u8 = undefined;
    var counted: Io.Writer.Discarding = .init(&buffer);
    inspect.write(&counted.writer, built, sample_count, lengths) catch unreachable;
    const size = std.math.cast(usize, counted.fullCount()) orelse return nomem(&t.err);
    const bytes = allocator.alloc(u8, size) catch return nomem(&t.err);
    var text: Io.Writer = .fixed(bytes);
    inspect.write(&text, built, sample_count, lengths) catch unreachable;
    t.inspection_bytes = bytes;
    dst.* = bytes.ptr;
    count.* = bytes.len;
    return .ok;
}

fn serialized(h: ?*Handle, comptime format: enum { pht, kml }, out: ?*?[*]const u8, len: ?*usize) Status {
    const t = h orelse return .arg;
    t.err.begin();
    const dst = out orelse return .arg;
    const count = len orelse return .arg;
    dst.* = null;
    count.* = 0;
    const traj = t.trajectory() orelse return noTrajectory(t);
    if (format == .pht) if (t.refusal()) |why| {
        t.err.set("the path {s}, so no PHT is written of it", .{why});
        return .input;
    };
    const saved = switch (format) {
        .pht => &t.pht_bytes,
        .kml => &t.kml_bytes,
    };
    if (saved.* == null) {
        var text: Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        switch (format) {
            .pht => shared_trajectory.pht.write(&text.writer, traj) catch |e| switch (e) {
                error.TooLarge => {
                    t.err.set("the path takes more than the {d} bytes a PHT holds, so no PHT is written of it", .{shared_trajectory.pht.max_bytes});
                    return .input;
                },
                error.WriteFailed => return nomem(&t.err),
            },
            .kml => kml.write(&text.writer, traj) catch return nomem(&t.err),
        }
        saved.* = text.toOwnedSlice() catch return nomem(&t.err);
    }
    const bytes = saved.*.?;
    dst.* = bytes.ptr;
    count.* = bytes.len;
    return .ok;
}

fn noTrajectory(t: *Handle) Status {
    t.err.set("the object holds no trajectory: its source has errors", .{});
    return .arg;
}

pub fn pharos_traj_error(h: ?*const Handle) callconv(.c) [*:0]const u8 {
    return if (h) |t| t.err.cstr() else "";
}

pub fn pharos_traj_destroy(h: ?*Handle) callconv(.c) void {
    const t = h orelse return;
    if (t.pht_bytes) |bytes| allocator.free(bytes);
    if (t.kml_bytes) |bytes| allocator.free(bytes);
    if (t.inspection_bytes) |bytes| allocator.free(bytes);
    t.arena.deinit();
    allocator.destroy(t);
}

comptime {
    capi.exportFunctions("pharos_traj", @This());
}
