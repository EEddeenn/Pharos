const std = @import("std");
const Io = std.Io;
const bundle = @import("shared").bundle;
const engine = @import("../engine.zig");
const gain = @import("../synth.zig").gain;
const io = @import("../io.zig");
const capi = @import("shared").capi;
const common = @import("common.zig");
const convert = @import("convert.zig");
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;
const copyOut = common.copyOut;

pub const Options = extern struct {
    workers: u32 = 0,
    seed: u64 = 0,
    noise: u32 = 0,
    gain: u32 = 0,
    gain_db: f64 = 0,
};

pub const ManifestFields = extern struct {
    start_time_iso: ?[*:0]const u8 = null,
    run_id: ?[*:0]const u8 = null,
    output_path: ?[*:0]const u8 = null,
};

pub const Info = extern struct {
    format_bits: u32,
    sample_rate_hz: u64,
    center_hz: i64,
    samples_per_epoch: u32,
    workers: u32,
    bytes_per_epoch: u64,
    total_epochs: u64,
    start_gps_ms: i64,
    start_gps_sub_ms: f64,
    leap_change_gps_ms: i64,
    leap_seconds: i32,
    leap_seconds_after: i32,
};

pub const Block = extern struct {
    epoch_first: u64,
    epochs: u32,
    bytes: usize,
    clipped: u64,
    applied: [*]const convert.Applied,
    applied_count: usize,
    failed: u32,
};

pub const Handle = struct {
    arena: std.heap.ArenaAllocator,
    b: bundle.Bundle,
    run: *engine.run.Run,
    applied: [engine.commands.capacity]convert.Applied = undefined,
    err: ErrorBuffer = .{},
};

fn discard(r: *Handle) void {
    r.arena.deinit();
    allocator.destroy(r);
}

pub fn pharos_run_create(data: ?[*]const u8, len: usize, o: ?*const Options, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const dst = out orelse return .arg;
    dst.* = null;
    const bytes = (data orelse return .arg)[0..len];
    const opts = if (o) |given| given.* else Options{};
    const noise = std.enums.fromInt(engine.run.NoiseMode, opts.noise) orelse {
        common.thread_error.set("noise mode {d} is not defined (0 counter, 1 off)", .{opts.noise});
        return .arg;
    };
    const mode = std.enums.fromInt(gain.Mode, opts.gain) orelse {
        common.thread_error.set("gain mode {d} is not defined (0 adaptive, 1 constant)", .{opts.gain});
        return .arg;
    };
    const constant_gain: ?gain.Db = switch (mode) {
        .adaptive => if (opts.gain_db == 0) null else {
            common.thread_error.set("gain_db must be 0 under the adaptive gain, got {d}", .{opts.gain_db});
            return .arg;
        },
        .constant => gain.Db.fromValue(opts.gain_db) orelse {
            common.thread_error.set("gain_db must lie within {d}..{d}, got {d}", .{ gain.Db.min.db, gain.Db.max.db, opts.gain_db });
            return .arg;
        },
    };
    const r = allocator.create(Handle) catch return nomem(&common.thread_error);
    r.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .b = undefined, .run = undefined };
    const read = capi.readBundle(Status, r.arena.allocator(), bytes, &common.thread_error, &r.b);
    if (read != .ok) {
        discard(r);
        return read;
    }
    const m = &r.b.scenario;
    const samples = m.samples orelse {
        common.thread_error.set("the bundle has no samples block: nothing to generate", .{});
        discard(r);
        return .bundle;
    };
    r.run = engine.run.Run.create(allocator, &r.b, samples, .{
        .seed = opts.seed,
        .workers = opts.workers,
        .noise = noise,
        .gain = constant_gain,
    }) catch |e| {
        common.thread_error.set("cannot create the run: {f}", .{engine.run.createFailure(e)});
        discard(r);
        return switch (e) {
            error.OutOfMemory => .nomem,
            error.ThreadSpawnFailed, error.Internal => .internal,
            error.MessageSet, error.MissingEarthOrientation, error.MissingTimeOffset, error.MissingUtcParameters => |f| capi.failed(Status, f),
        };
    };
    dst.* = r;
    return .ok;
}

pub fn pharos_run_info_get(r: ?*const Handle, out: ?*Info) callconv(.c) Status {
    const run = (r orelse return .arg).run;
    const o = out orelse return .arg;
    const info: Info = .{
        .format_bits = run.info.samples.format.bitsPerComponent(),
        .sample_rate_hz = run.info.samples.sample_rate.hz(),
        .center_hz = run.info.samples.center.hz,
        .samples_per_epoch = run.info.samples_per_epoch,
        .workers = run.info.workers,
        .bytes_per_epoch = run.info.bytes_per_epoch,
        .total_epochs = run.info.span.epochs,
        .start_gps_ms = run.info.span.start.ms,
        .start_gps_sub_ms = run.info.span.start.sub_ms,
        .leap_change_gps_ms = if (run.info.span.leap_change) |t| t.ms else 0,
        .leap_seconds = run.info.span.leap_seconds,
        .leap_seconds_after = run.info.span.leap_seconds_after,
    };
    o.* = info;
    return .ok;
}

pub fn pharos_run_pull(r: ?*Handle, buf: ?[*]u8, cap: usize, max_epochs: u32, out: ?*Block) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.begin();
    const o = out orelse return .arg;
    const bytes = (buf orelse return .arg)[0..cap];
    const block = h.run.pull(bytes, max_epochs) catch |e| return pullFailed(h, e);
    for (block.applied, 0..) |a, i| h.applied[i] = .{ .epoch = a.epoch.ms, .command = capi.command.toC(a.command) };
    const status: Status = if (block.failed) |e| pullFailed(h, e) else if (block.epochs == 0) .end else .ok;
    o.* = .{
        .epoch_first = block.epoch_first.ms,
        .epochs = block.epochs,
        .bytes = block.bytes,
        .clipped = block.clipped,
        .applied = &h.applied,
        .applied_count = block.applied.len,
        .failed = if (block.failed != null) @intCast(@intFromEnum(status)) else 0,
    };
    return status;
}

fn pullFailed(h: *Handle, e: engine.run.PullError) Status {
    const status: Status = switch (e) {
        error.BufferTooSmall => {
            h.err.set("max_epochs is 0 or the buffer holds no epoch of {d} bytes", .{h.run.info.bytes_per_epoch});
            return .arg;
        },
        error.OutOfMemory => return nomem(&h.err),
        error.MessageSet, error.MissingEarthOrientation, error.MissingTimeOffset, error.MissingUtcParameters => |f| capi.failed(Status, f),
        error.Internal => .internal,
    };
    h.err.set("epoch {d} of {d} could not be generated: {s} ({s})", .{ h.run.epoch.ms, h.run.info.span.epochs, @errorName(e), engine.run.reason(e) });
    return status;
}

pub fn pharos_run_seek(r: ?*Handle, epoch: u64) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.begin();
    h.run.seek(.{ .ms = epoch }) catch |e| switch (e) {
        error.EpochOutOfRange => {
            h.err.set("epoch {d} lies beyond the run's {d} epochs", .{ epoch, h.run.info.span.epochs });
            return .arg;
        },
        error.AdaptiveGain => {
            h.err.set("seeking needs a constant gain: {s}", .{engine.run.reason(e)});
            return .arg;
        },
        error.CommandsApplied => {
            h.err.set("seeking to epoch {d} is refused: {s}", .{ epoch, engine.run.reason(e) });
            return .arg;
        },
        else => |failure| return pullFailed(h, failure),
    };
    return .ok;
}

pub fn pharos_run_submit(r: ?*Handle, c: ?*const capi.command.Command) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.begin();
    const cmd = capi.command.decode((c orelse return .arg).*, &h.err) orelse return .arg;
    h.run.submit(cmd) catch |e| switch (e) {
        error.TooManyPending => {
            h.err.set("the command queue holds {d} pending commands: pull, then submit again", .{engine.commands.capacity});
            return .busy;
        },
        error.EpochPassed, error.InvalidValue => |rejection| return capi.command.rejected(Status, &h.err, rejection),
    };
    return .ok;
}

pub fn pharos_run_next_event(r: ?*Handle, out: ?*convert.Event) callconv(.c) c_int {
    const h = r orelse return 0;
    const o = out orelse return 0;
    const ev = h.run.nextEvent() orelse return 0;
    o.* = convert.eventToC(ev);
    return 1;
}

pub fn pharos_run_events_dropped(r: ?*const Handle) callconv(.c) u32 {
    return if (r) |h| h.run.eventsDropped() else 0;
}

pub fn pharos_run_manifest_json(r: ?*Handle, f: ?*const ManifestFields, buf: ?[*]u8, cap: usize, len: ?*usize) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.begin();
    const fields = if (f) |given| given.* else ManifestFields{};
    inline for (.{ fields.start_time_iso, fields.run_id, fields.output_path }, .{ "start_time_iso", "run_id", "output_path" }) |value, name| {
        if (!std.unicode.utf8ValidateSlice(span(value))) {
            h.err.set("{s} is not UTF-8", .{name});
            return .arg;
        }
    }
    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    io.manifest.write(allocator, &text.writer, &h.b, h.run.info.samples, h.run.info.span, h.run.ionosphere(), h.run.generatedSignals(), h.run.entryEpoch(), h.run.total_bytes, .{
        .start_time = span(fields.start_time_iso),
        .run_id = span(fields.run_id),
        .file = span(fields.output_path),
    }) catch return nomem(&h.err);
    return copyOut(text.written(), buf, cap, len);
}

fn span(text: ?[*:0]const u8) []const u8 {
    return if (text) |p| std.mem.span(p) else "";
}

pub fn pharos_run_tag_text(r: ?*Handle, buf: ?[*]u8, cap: usize, len: ?*usize) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.begin();
    var buffer: [io.tag.max_len]u8 = undefined;
    const text = io.tag.text(&buffer, h.run.info.samples, h.run.entryTime()) orelse {
        h.err.set("the .tag format has no {s} format", .{h.run.info.samples.format.name()});
        return .arg;
    };
    return copyOut(text, buf, cap, len);
}

pub fn pharos_run_to_file(r: ?*Handle, path: ?[*:0]const u8, bytes_written: ?*u64) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.begin();
    const p = std.mem.span(path orelse return .arg);
    var threaded: Io.Threaded = .init_single_threaded;
    const written = io.sink.writeRun(allocator, threaded.io(), p, h.run, h.run.events.count(), dropEvents) catch |e| {
        if (bytes_written) |b| b.* = 0;
        if (e == error.OutOfMemory) return nomem(&h.err);
        return cannotWrite(h, p, e);
    };
    if (bytes_written) |b| b.* = written.bytes_on_file;
    if (written.write_failed) |e| return cannotWrite(h, p, e);
    if (written.failed) |e| return pullFailed(h, e);
    return .ok;
}

fn cannotWrite(h: *Handle, path: []const u8, e: anyerror) Status {
    var short: [capi.elided_len]u8 = undefined;
    h.err.set("cannot write {s}: {s}", .{ capi.elide(&short, path), @errorName(e) });
    return .io;
}

fn dropEvents(queued: usize, run: *engine.run.Run, _: engine.run.Block) void {
    run.events.truncate(queued);
}

pub fn pharos_run_error(r: ?*const Handle) callconv(.c) [*:0]const u8 {
    return if (r) |h| h.err.cstr() else "";
}

pub fn pharos_run_destroy(r: ?*Handle) callconv(.c) void {
    const h = r orelse return;
    h.run.destroy();
    h.arena.deinit();
    allocator.destroy(h);
}

comptime {
    capi.exportFunctions("pharos_run", @This());
}
