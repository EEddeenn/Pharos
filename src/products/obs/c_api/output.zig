const std = @import("std");
const c_command = @import("interface/c/command");
const target = @import("base/target");
const output = @import("products/obs/output/session");
const source = @import("products/obs/c_api/source");
const Io = std.Io;
const common = @import("products/obs/c_api/context").Context;
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

pub const Info = extern struct {
    kind: u32 = 0,
    epochs: u64 = 0,
    interval_ms: u32 = 0,
    tracked: u32 = 0,
    first_epoch: u64 = 0,
    last_epoch: u64 = 0,
};

pub const Batch = extern struct {
    data: ?[*]const u8 = null,
    len: usize = 0,
    completed_epochs: u64 = 0,
    generated_through: u64 = 0,
    has_generated: u32 = 0,
    end: u32 = 0,
};

pub const Handle = struct {
    source: *source.Handle,
    file: *output.File,
    err: ErrorBuffer = .{},
};

pub const unavailable: []const []const u8 = if (target.has_wall_clock) &.{} else &.{"pharos_obs_output_create_observation_now"};

pub fn pharos_obs_output_create_observation(input: ?*source.Handle, created_unix_s: i64, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const dst = out orelse return .arg;
    dst.* = null;
    const origin = input orelse return .arg;
    const created = output.Created.fromUnixSeconds(created_unix_s) orelse {
        common.thread_error.set("created_unix_s must be from {d} to {d}, got {d}", .{ output.Created.min.unix_s, output.Created.max.unix_s, created_unix_s });
        return .arg;
    };
    return create(origin, .{ .observation = created }, dst);
}

pub fn pharos_obs_output_create_observation_now(input: ?*source.Handle, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const dst = out orelse return .arg;
    dst.* = null;
    const origin = input orelse return .arg;
    var threaded: Io.Threaded = .init_single_threaded;
    var read_s: i64 = 0;
    const created = output.Created.fromWallClock(threaded.io(), &read_s) orelse {
        common.thread_error.set("the wall clock must read from {d} to {d} s, got {d}", .{ output.Created.min.unix_s, output.Created.max.unix_s, read_s });
        return .arg;
    };
    return create(origin, .{ .observation = created }, dst);
}

pub fn pharos_obs_output_create_position(input: ?*source.Handle, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const dst = out orelse return .arg;
    dst.* = null;
    const origin = input orelse return .arg;
    return create(origin, .position, dst);
}

pub fn pharos_obs_output_info_get(output_handle: ?*const Handle, out: ?*Info) callconv(.c) Status {
    const h = output_handle orelse return .arg;
    const dst = out orelse return .arg;
    const summary = h.file.summary();
    dst.* = .{
        .kind = @backingInt(summary.kind),
        .epochs = summary.epochs,
        .interval_ms = summary.interval_ms,
        .tracked = @intCast(summary.tracked orelse 0),
        .first_epoch = summary.first_ms,
        .last_epoch = summary.last_ms,
    };
    return .ok;
}

pub fn pharos_obs_output_set_range(output_handle: ?*Handle, first_epoch: u64, end_epoch: u64) callconv(.c) Status {
    const h = output_handle orelse return .arg;
    h.err.clear();
    h.file.setRange(.{ .first = first_epoch, .end = end_epoch }) catch |e| {
        switch (e) {
            error.Begun => h.err.set("the file has begun: a range comes before the first pull", .{}),
            error.EpochOutOfRange => h.err.set("end_epoch must be at most {d}, got {d}", .{ h.file.fullRange().end, end_epoch }),
            error.EmptyRange => h.err.set("end_epoch must be above first_epoch ({d}), got {d}", .{ first_epoch, end_epoch }),
            error.NoEpochs => h.err.set("first_epoch {d} and end_epoch {d} select no output epoch", .{ first_epoch, end_epoch }),
        }
        return .arg;
    };
    return .ok;
}

pub fn pharos_obs_output_pull(output_handle: ?*Handle, max_epochs: u32, out: ?*Batch) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const h = output_handle orelse return .arg;
    h.err.clear();
    const batch = h.file.pull(max_epochs) catch |e| switch (e) {
        error.InvalidBatchSize => {
            h.err.set("max_epochs must be from 1 to {d}, got {d}", .{ output.max_batch_epochs, max_epochs });
            return .arg;
        },
    };
    dst.* = .{
        .data = if (batch.bytes.len == 0) null else batch.bytes.ptr,
        .len = batch.bytes.len,
        .completed_epochs = batch.completed_epochs,
        .generated_through = batch.generated_through orelse 0,
        .has_generated = @intFromBool(batch.generated_through != null),
        .end = @intFromBool(batch.end),
    };
    return if (batch.end and batch.bytes.len == 0) .end else .ok;
}

pub fn pharos_obs_output_submit(output_handle: ?*Handle, c: ?*const c_command.Command) callconv(.c) Status {
    const h = output_handle orelse return .arg;
    h.err.clear();
    const cmd = c_command.decode((c orelse return .arg).*, &h.err) orelse return .arg;
    h.file.submit(cmd) catch |e| switch (e) {
        error.OutOfMemory => return nomem(&h.err),
        error.InvalidValue, error.EpochPassed => |rejection| return c_command.rejected(Status, &h.err, rejection),
        error.CommandsNotSupported => {
            h.err.set("position files do not accept commands", .{});
            return .arg;
        },
    };
    return .ok;
}

pub fn pharos_obs_output_error(output_handle: ?*const Handle) callconv(.c) [*:0]const u8 {
    return if (output_handle) |h| h.err.cstr() else "";
}

pub fn pharos_obs_output_destroy(output_handle: ?*Handle) callconv(.c) void {
    const h = output_handle orelse return;
    h.file.destroy();
    h.source.release();
    allocator.destroy(h);
}

fn create(origin: *source.Handle, request: output.OutputRequest, dst: *?*Handle) Status {
    const h = allocator.create(Handle) catch return nomem(&common.thread_error);
    origin.retain();
    h.* = .{ .source = origin, .file = undefined };
    h.file = output.File.create(allocator, &origin.b.scenario, request) catch |e| {
        const kind: output.OutputKind = request;
        common.thread_error.set("cannot create the {s} file: {s}", .{ output.OutputKind.words.get(kind), output.reason(e) });
        origin.release();
        allocator.destroy(h);
        return switch (e) {
            error.OutOfMemory => .nomem,
            error.NoSuchOutput => .bundle,
        };
    };
    dst.* = h;
    return .ok;
}
