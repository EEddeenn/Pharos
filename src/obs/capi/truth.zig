const std = @import("std");
const core = @import("shared").core;
const stage = @import("shared").stage;
const capi = @import("shared").capi;
const truth = @import("../truth.zig");
const inspect = @import("../inspect.zig");
const source = @import("source.zig");
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;
const rad2deg = core.constants.rad2deg;

const mask_digits = 1e9;

pub const Satellite = extern struct {
    system: u32,
    svid: u32,
    record: u32,
    above_mask: u32,
    masked_out: u32,
    azimuth_deg: f64,
    elevation_deg: f64,
};

pub const Signal = extern struct {
    system: u32,
    svid: u32,
    signal: u32,
    channel: u32,
    commanded: u32,
    cn0_dbhz: f64,
};

pub const Epoch = extern struct {
    pos: [3]f64 = .{ 0, 0, 0 },
    vel: [3]f64 = .{ 0, 0, 0 },
    lat_deg: f64 = 0,
    lon_deg: f64 = 0,
    altitude_m: f64 = 0,
    elevation_mask_deg: f64 = 0,
    pdop: f64 = 0,
    hdop: f64 = 0,
    vdop: f64 = 0,
    satellites: [*]const Satellite,
    satellite_count: usize = 0,
    signals: [*]const Signal,
    signal_count: usize = 0,
};

pub const InspectGroup = enum(u32) { all = 0, model = 1, navigation = 2, messages = 4, service = 8 };

pub const InspectQuery = extern struct {
    epoch: u64,
    system: u32,
    svid: u32,
    signal: u32,
    groups: u32 = 0,
};

pub const Handle = struct {
    source: *source.Handle,
    truth: *truth.Truth,
    satellites: []Satellite = &.{},
    signals: []Signal = &.{},
    inspect_arena: std.heap.ArenaAllocator,
    json: std.Io.Writer.Allocating,
    err: ErrorBuffer = .{},
};

fn discard(h: *Handle) void {
    allocator.free(h.satellites);
    allocator.free(h.signals);
    h.inspect_arena.deinit();
    h.json.deinit();
    h.source.release();
    allocator.destroy(h);
}

pub fn pharos_obs_truth_create(input: ?*source.Handle, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const dst = out orelse return .arg;
    dst.* = null;
    const origin = input orelse return .arg;
    const h = allocator.create(Handle) catch return nomem(&common.thread_error);
    origin.retain();
    h.* = .{ .source = origin, .truth = undefined, .inspect_arena = .init(allocator), .json = .init(allocator) };
    h.truth = truth.Truth.create(allocator, &origin.b) catch {
        discard(h);
        return nomem(&common.thread_error);
    };
    h.satellites = allocator.alloc(Satellite, h.truth.satelliteCount()) catch {
        pharos_obs_truth_destroy(h);
        return nomem(&common.thread_error);
    };
    h.signals = allocator.alloc(Signal, h.truth.signalCount()) catch {
        pharos_obs_truth_destroy(h);
        return nomem(&common.thread_error);
    };
    dst.* = h;
    return .ok;
}

pub fn pharos_obs_truth_get(t: ?*Handle, epoch: u64, out: ?*Epoch) callconv(.c) Status {
    const h = t orelse return .arg;
    h.err.begin();
    const o = out orelse return .arg;
    return answer(h, h.truth.at(.{ .ms = epoch }), epoch, o);
}

pub fn pharos_obs_truth_sky(t: ?*Handle, epoch: u64, out: ?*Epoch) callconv(.c) Status {
    const h = t orelse return .arg;
    h.err.begin();
    const o = out orelse return .arg;
    return answer(h, h.truth.sky(.{ .ms = epoch }), epoch, o);
}

pub fn pharos_obs_truth_inspect(t: ?*Handle, query: ?*const InspectQuery, out: ?*common.Bytes) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const h = t orelse return .arg;
    h.err.begin();
    const q = query orelse return .arg;
    const system = std.enums.fromInt(core.types.System, q.system) orelse return malformedInspect(h);
    const sat = core.types.SatId.fromPrn(system, q.svid) catch return malformedInspect(h);
    const signal = std.enums.fromInt(core.types.Signal, q.signal) orelse return malformedInspect(h);
    if (q.groups & ~@as(u32, 15) != 0) return malformedInspect(h);
    var groups: inspect.Groups = if (q.groups == 0) .initFull() else .initEmpty();
    if (q.groups != 0) {
        inline for (.{ inspect.Group.model, inspect.Group.navigation, inspect.Group.messages, inspect.Group.service }, .{ 1, 2, 4, 8 }) |group, bit| {
            if (q.groups & bit != 0) groups.insert(group);
        }
    }

    _ = h.inspect_arena.reset(.retain_capacity);
    h.json.clearRetainingCapacity();
    const result = h.truth.inspect(h.inspect_arena.allocator(), .{
        .epoch = .{ .ms = q.epoch },
        .sat = sat,
        .signal = signal,
        .groups = groups,
    }) catch |e| return switch (e) {
        error.InvalidValue => malformedInspect(h),
        else => |failure| failedQuery(h, failure, q.epoch),
    };
    std.json.Stringify.value(result, .{ .emit_null_optional_fields = false }, &h.json.writer) catch return nomem(&h.err);
    const bytes = h.json.written();
    dst.* = .{ .data = bytes.ptr, .len = bytes.len };
    return .ok;
}

pub fn pharos_obs_truth_visible_counts(t: ?*Handle, epochs: ?[*]const u64, count: usize, counts: ?[*]u32) callconv(.c) Status {
    const h = t orelse return .arg;
    h.err.begin();
    if (count == 0) return .ok;
    const requested = (epochs orelse return .arg)[0..count];
    const dst = (counts orelse return .arg)[0..count];
    for (requested, dst) |epoch, *value| {
        value.* = @intCast(h.truth.visibleCount(.{ .ms = epoch }) catch |e| return failedQuery(h, e, epoch));
    }
    return .ok;
}

fn malformedInspect(h: *Handle) Status {
    h.err.set("malformed inspect query", .{});
    return .arg;
}

fn answer(h: *Handle, result: truth.QueryError!truth.Sky, epoch: u64, o: *Epoch) Status {
    const sky = result catch |e| return failedQuery(h, e, epoch);
    for (sky.satellites, h.satellites[0..sky.satellites.len]) |s, *c| c.* = .{
        .system = @intFromEnum(s.sat.system),
        .svid = s.sat.prn(),
        .record = @intFromBool(s.record),
        .above_mask = @intFromBool(s.above_mask),
        .masked_out = @intFromBool(s.masked_out),
        .azimuth_deg = rad2deg(s.az_rad),
        .elevation_deg = rad2deg(s.el_rad),
    };
    for (sky.signals, h.signals[0..sky.signals.len]) |s, *c| c.* = .{
        .system = @intFromEnum(s.sat.system),
        .svid = s.sat.prn(),
        .signal = @intFromEnum(s.signal),
        .channel = @intFromEnum(s.state),
        .commanded = @intFromBool(s.commanded),
        .cn0_dbhz = s.cn0_dbhz,
    };
    const dop = sky.dop orelse truth.Dop{ .pdop = 0, .hdop = 0, .vdop = 0 };
    o.* = .{
        .pos = sky.pos.toArray(),
        .vel = sky.vel.toArray(),
        .lat_deg = sky.lla.latDeg(),
        .lon_deg = sky.lla.lonDeg(),
        .altitude_m = core.geoid.altitude(sky.lla),
        .elevation_mask_deg = @round(rad2deg(sky.mask_rad) * mask_digits) / mask_digits,
        .pdop = dop.pdop,
        .hdop = dop.hdop,
        .vdop = dop.vdop,
        .satellites = h.satellites.ptr,
        .satellite_count = sky.satellites.len,
        .signals = h.signals.ptr,
        .signal_count = sky.signals.len,
    };
    return .ok;
}

fn failedQuery(h: *Handle, e: truth.QueryError, epoch: u64) Status {
    switch (e) {
        error.EpochOutOfRange => {
            h.err.set("epoch {d} lies beyond the run's {d} epochs", .{ epoch, h.truth.span.epochs });
            return .arg;
        },
        error.NoSamples => {
            h.err.set("the bundle has no samples block: no run to replay", .{});
            return .bundle;
        },
        error.OutOfMemory => return nomem(&h.err),
        error.MessageSet, error.MissingEarthOrientation, error.MissingTimeOffset, error.MissingUtcParameters => |f| {
            h.err.set("epoch {d} of {d} could not be planned: {s} ({s})", .{ epoch, h.truth.span.epochs, @errorName(f), stage.messages.reason(f) });
            return capi.failed(Status, f);
        },
    }
}

pub fn pharos_obs_truth_submit(t: ?*Handle, c: ?*const capi.command.Command) callconv(.c) Status {
    const h = t orelse return .arg;
    h.err.begin();
    const cmd = capi.command.decode((c orelse return .arg).*, &h.err) orelse return .arg;
    h.truth.submit(cmd) catch |e| switch (e) {
        error.OutOfMemory => return nomem(&h.err),
        error.InvalidValue => |rejection| return capi.command.rejected(Status, &h.err, rejection),
    };
    return .ok;
}

pub fn pharos_obs_truth_error(t: ?*const Handle) callconv(.c) [*:0]const u8 {
    return if (t) |h| h.err.cstr() else "";
}

pub fn pharos_obs_truth_destroy(t: ?*Handle) callconv(.c) void {
    const h = t orelse return;
    h.truth.destroy();
    discard(h);
}

comptime {
    capi.exportFunctions("pharos_obs", @This());
}
