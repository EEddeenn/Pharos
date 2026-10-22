const std = @import("std");
const geoid = @import("domain/earth/geoid/model");
const pht_read = @import("pht/read");
const pht_write = @import("pht/write");
const diagnostic_types = @import("base/diagnostics");
const c_diagnostics = @import("interface/c/diagnostics");
const coordinates = @import("domain/earth/coordinates");
const shared_trajectory = @import("domain/trajectory/trajectory");
const stationary = @import("products/traj/construction/static");
const source = @import("products/traj/pipeline");
const inspect = @import("products/traj/output/inspect");
const kml = @import("products/traj/output/kml");
const stats = @import("products/traj/output/stats");
const frame = @import("products/traj/motion/geometry/frame");
const Io = std.Io;
const Number = @import("base/text/number").Number;
const ByteView = @import("interface/c/buffers").ByteView;
const DiagnosticView = c_diagnostics.DiagnosticView;
const Trajectory = shared_trajectory.Trajectory;
const Diagnostics = diagnostic_types.Diagnostics;
const Range = @import("base/math/range").Range;
const common = @import("products/traj/c_api/context").Context;
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

pub const Diag = c_diagnostics.Diag;

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
            .built => |built| built.path.trajectory,
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

pub fn pharos_traj_build(json: ?[*]const u8, len: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const o = out orelse return .arg;
    o.* = null;
    const bytes = (json orelse return .arg)[0..len];
    const h = create() orelse return nomem(&common.thread_error);
    const arena = h.arena.allocator();
    var diags = Diagnostics{ .arena = arena };
    const built = source.build(allocator, arena, bytes, &diags) catch |e| {
        if (e == error.OutOfMemory) return nomemDestroy(h);
        return finish(h, &diags, .input, o);
    };
    h.content = .{ .built = built };
    return finish(h, &diags, if (built.refusal() == null) .ok else .input, o);
}

pub fn pharos_traj_read(bytes: ?[*]const u8, len: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const o = out orelse return .arg;
    o.* = null;
    const data = (bytes orelse return .arg)[0..len];
    const h = create() orelse return nomem(&common.thread_error);
    const arena = h.arena.allocator();
    var diags = Diagnostics{ .arena = arena };
    const traj = pht_read.read(arena, data, diags.forSource("")) catch |e| {
        if (e == error.OutOfMemory) return nomemDestroy(h);
        return finish(h, &diags, .input, o);
    };
    h.content = .{ .loaded = traj };
    return finish(h, &diags, .ok, o);
}

pub fn pharos_traj_static(lat_deg: f64, lon_deg: f64, altitude_m: f64, duration_s: f64, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
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

pub fn pharos_traj_diagnostics(h: ?*const Handle, out: ?*DiagnosticView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const t = h orelse return .arg;
    dst.* = .fromSlice(t.c_diags);
    return .ok;
}

pub fn pharos_traj_has_path(h: ?*const Handle) callconv(.c) c_int {
    return @intFromBool(trajectoryOf(h) != null);
}

pub fn pharos_traj_info_get(h: ?*Handle, out: ?*Info) callconv(.c) Status {
    const t = h orelse return .arg;
    t.err.clear();
    const o = out orelse return .arg;
    const traj = t.trajectory() orelse return noTrajectory(t);
    if (t.info == null) {
        const st = stats.of(allocator, traj) catch return nomem(&t.err);
        t.info = .{
            .velocity_steps = @intCast(st.velocity_steps),
            .knots = st.knots,
            .duration_s = st.duration_s,
            .max_speed_mps = st.max_speed_mps,
            .max_acceleration_mps2 = st.max_acceleration_mps2,
            .max_jerk_mps3 = st.max_jerk_mps3,
            .min_altitude_m = st.min_altitude_m,
            .max_altitude_m = st.max_altitude_m,
            .acceleration_steps = @intCast(st.acceleration_steps),
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
    const p = coordinates.ecefToLla(s.pos);
    // The course as inspect reads it: none below a millimetre a second, in [0, 360).
    const reading = frame.Reading.of(s, .ellipsoid, null);
    const state: State = .{
        .pos = s.pos.toArray(),
        .vel = s.vel.toArray(),
        .acc = s.acc.toArray(),
        .lat_deg = p.latDeg(),
        .lon_deg = p.lonDeg(),
        .altitude_m = geoid.altitude(p),
        .speed_mps = s.vel.norm(),
        .course_deg = reading.course_deg orelse std.math.nan(f64),
    };
    o.* = state;
    return .ok;
}

pub fn pharos_traj_bytes(h: ?*Handle, out: ?*ByteView) callconv(.c) Status {
    return serialized(h, .pht, out);
}

pub fn pharos_traj_kml(h: ?*Handle, out: ?*ByteView) callconv(.c) Status {
    return serialized(h, .kml, out);
}

pub fn pharos_traj_inspect(h: ?*Handle, sample_count: usize, out: ?*ByteView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const t = h orelse return .arg;
    t.err.clear();
    if (sample_count < 2) return invalidSampleCount(t, sample_count);
    const built = switch (t.content) {
        .none => return noTrajectory(t),
        .loaded => return .ok,
        .built => |*built| built,
    };
    // Release the previous text before allocating its replacement in the WebAssembly instance.
    if (t.inspection_bytes) |previous| allocator.free(previous);
    t.inspection_bytes = null;
    var inspection = inspect.Inspection.init(allocator, built, sample_count) catch |e| switch (e) {
        error.OutOfMemory => return nomem(&t.err),
        error.InvalidSampleCount => unreachable,
    };
    defer inspection.deinit();
    var buffer: [4096]u8 = undefined;
    var counted: Io.Writer.Discarding = .init(&buffer);
    inspection.write(&counted.writer) catch unreachable;
    const size = std.math.cast(usize, counted.fullCount()) orelse return nomem(&t.err);
    const bytes = allocator.alloc(u8, size) catch return nomem(&t.err);
    var text: Io.Writer = .fixed(bytes);
    inspection.write(&text) catch unreachable;
    t.inspection_bytes = bytes;
    dst.* = .fromSlice(bytes);
    return .ok;
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
    h.c_diags = c_diagnostics.copy(h.arena.allocator(), diags.slice()) catch return nomemDestroy(h);
    if (status == .input) if (diags.firstError()) |d| h.err.set("{f}", .{d});
    out.* = h;
    return status;
}

fn outside(comptime name: []const u8, range: Range, value: f64) void {
    common.thread_error.set(name ++ " must be {f}, got {f}", .{ range, Number{ .value = value, .outside = range } });
}

fn trajectoryOf(h: ?*const Handle) ?Trajectory {
    return (h orelse return null).trajectory();
}

fn invalidSampleCount(t: *Handle, sample_count: usize) Status {
    t.err.set("sample_count must be at least 2, got {d}", .{sample_count});
    return .arg;
}

fn serialized(h: ?*Handle, comptime format: enum { pht, kml }, out: ?*ByteView) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const t = h orelse return .arg;
    t.err.clear();
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
        var encoded: Io.Writer.Allocating = .init(allocator);
        defer encoded.deinit();
        switch (format) {
            .pht => pht_write.write(&encoded.writer, traj) catch return nomem(&t.err),
            .kml => kml.write(&encoded.writer, traj) catch return nomem(&t.err),
        }
        saved.* = encoded.toOwnedSlice() catch return nomem(&t.err);
    }
    const bytes = saved.*.?;
    dst.* = .fromSlice(bytes);
    return .ok;
}

fn noTrajectory(t: *Handle) Status {
    t.err.set("the object holds no trajectory: its source has errors", .{});
    return .arg;
}
