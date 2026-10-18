const std = @import("std");
const Io = std.Io;
const core = @import("shared").core;
const coord = core.coord;
const shared_trajectory = @import("shared").trajectory;
const Trajectory = shared_trajectory.Trajectory;
const Diagnostics = @import("shared").core.diagnostics.Diagnostics;
const stationary = @import("../static.zig");
const source = @import("../source.zig");
const inspect = @import("../inspect.zig");
const kml = @import("../kml.zig");
const stats = @import("../stats.zig");
const capi = @import("shared").capi;
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

pub const Diag = capi.Diag;

pub const Handle = struct {
    arena: std.heap.ArenaAllocator,
    content: union(enum) { none, loaded: Trajectory, solved: source.Result } = .none,
    c_diags: []Diag = &.{},
    pht_bytes: ?[]u8 = null,
    kml_bytes: ?[]u8 = null,
    inspection_bytes: ?[]u8 = null,
    err: ErrorBuffer = .{},

    fn trajectory(self: *const Handle) ?Trajectory {
        return switch (self.content) {
            .none => null,
            .loaded => |traj| traj,
            .solved => |built| built.trajectory,
        };
    }

    fn verified(self: *const Handle) bool {
        return switch (self.content) {
            .none => false,
            .loaded => true,
            .solved => |built| built.report.verified,
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
    return build(json, len, .{}, out);
}

pub fn pharos_traj_build_within(json: ?[*]const u8, len: usize, max_work: usize, out: ?*?*Handle) callconv(.c) Status {
    return build(json, len, .{ .max_work = max_work }, out);
}

fn build(json: ?[*]const u8, len: usize, options: source.Options, out: ?*?*Handle) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const bytes = (json orelse return .arg)[0..len];
    const h = create() orelse return nomem(&common.thread_error);
    const arena = h.arena.allocator();
    var diags = Diagnostics.init(arena);
    const built = source.build(allocator, arena, bytes, options, &diags) catch |e| {
        if (e == error.OutOfMemory) return nomemDestroy(h);
        return finish(h, &diags, .input, o);
    };
    h.content = .{ .solved = built };
    return finish(h, &diags, if (h.verified()) .ok else .input, o);
}

pub fn pharos_traj_read(bytes: ?[*]const u8, len: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const data = (bytes orelse return .arg)[0..len];
    const h = create() orelse return nomem(&common.thread_error);
    const arena = h.arena.allocator();
    var diags = Diagnostics.init(arena);
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
            error.LatitudeOutOfRange => common.thread_error.set("lat_deg must lie within -{d}..{d}, got {d}", .{ stationary.max_latitude_deg, stationary.max_latitude_deg, lat_deg }),
            error.LongitudeOutOfRange => common.thread_error.set("lon_deg must lie within -{d}..{d}, got {d}", .{ stationary.max_longitude_deg, stationary.max_longitude_deg, lon_deg }),
            error.PositionOutOfRange => common.thread_error.set("altitude_m places the receiver outside {d}..{d} m from the geocentre, got {d}", .{ shared_trajectory.min_radius_m, shared_trajectory.max_radius_m, altitude_m }),
            error.DurationOutOfRange => common.thread_error.set("duration_s must lie within 0..{d}, got {d}", .{ shared_trajectory.max_duration_s, duration_s }),
        }
        pharos_traj_destroy(h);
        return .arg;
    };
    h.content = .{ .loaded = traj };
    o.* = h;
    return .ok;
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

pub fn pharos_traj_info_get(h: ?*const Handle, out: ?*Info) callconv(.c) Status {
    const traj = trajectoryOf(h) orelse return .arg;
    const o = out orelse return .arg;
    const st = stats.of(traj);
    const info: Info = .{
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
    };
    o.* = info;
    return .ok;
}

pub fn pharos_traj_state_get(h: ?*const Handle, t_s: f64, out: ?*State) callconv(.c) Status {
    const traj = trajectoryOf(h) orelse return .arg;
    const o = out orelse return .arg;
    const reach = shared_trajectory.max_duration_s;
    if (!(t_s >= -reach and t_s <= traj.duration() + reach)) return .arg;
    const s = traj.at(t_s);
    const p = coord.ecefToLla(s.pos);
    const travel = coord.speedCourseFromEnu(coord.EnuFrame.at(p).toEnu(s.vel));
    const state: State = .{
        .pos = s.pos.toArray(),
        .vel = s.vel.toArray(),
        .acc = s.acc.toArray(),
        .lat_deg = p.latDeg(),
        .lon_deg = p.lonDeg(),
        .altitude_m = core.geoid.altitude(p),
        .speed_mps = s.vel.norm(),
        .course_deg = if (travel.speed == 0) std.math.nan(f64) else core.constants.rad2deg(travel.course_rad),
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
        .solved => |built| built,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const inspection = inspect.of(arena.allocator(), built, sample_count) catch |err| switch (err) {
        error.OutOfMemory => return nomem(&t.err),
        error.InvalidSampleCount => unreachable,
    };
    const bytes = std.json.Stringify.valueAlloc(allocator, inspection, .{}) catch return nomem(&t.err);
    if (t.inspection_bytes) |previous| allocator.free(previous);
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
    if (format == .pht and !t.verified()) {
        t.err.set("the trajectory candidate has not passed verification", .{});
        return .input;
    }
    const saved = switch (format) {
        .pht => &t.pht_bytes,
        .kml => &t.kml_bytes,
    };
    if (saved.* == null) {
        var text: Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        switch (format) {
            .pht => shared_trajectory.pht.write(&text.writer, traj) catch return nomem(&t.err),
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
