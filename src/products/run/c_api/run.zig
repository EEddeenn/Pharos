const std = @import("std");
const manifest = @import("products/run/output/manifest");
const sink = @import("products/run/output/sink");
const commands = @import("products/run/engine/commands");
const engine_run = @import("products/run/engine/run");
const tag = @import("products/run/output/tag");
const diagnostic_types = @import("base/diagnostics");
const prepared_bundle = @import("phb/prepared");
const c_phb = @import("interface/c/phb");
const c_command = @import("interface/c/command");
const c_buffers = @import("interface/c/buffers");
const gain = @import("products/run/synthesis/gain");
const convert = @import("products/run/c_api/convert");
const Io = std.Io;
const FileError = @import("base/text/file_error").FileError;
const Escaped = diagnostic_types.Escaped;
const Number = @import("base/text/number").Number;
const Range = @import("base/math/range").Range;
const common = @import("products/run/c_api/context").Context;
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

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
};

pub const Handle = struct {
    arena: std.heap.ArenaAllocator,
    b: prepared_bundle.PreparedBundle,
    run: *engine_run.Run,
    applied: [commands.capacity]convert.Applied = undefined,
    err: ErrorBuffer = .{},
};

pub fn pharos_run_create(data: ?[*]const u8, len: usize, o: ?*const Options, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const dst = out orelse return .arg;
    dst.* = null;
    const bytes = (data orelse return .arg)[0..len];
    const options = if (o) |given| given.* else Options{};
    const noise = std.enums.fromInt(engine_run.NoiseMode, options.noise) orelse {
        common.thread_error.set("noise mode {d} is not defined (0 counter, 1 off)", .{options.noise});
        return .arg;
    };
    const mode = std.enums.fromInt(gain.Mode, options.gain) orelse {
        common.thread_error.set("gain mode {d} is not defined (0 adaptive, 1 constant)", .{options.gain});
        return .arg;
    };
    const setting: engine_run.GainSetting = switch (mode) {
        .adaptive => if (options.gain_db == 0) .adaptive else {
            common.thread_error.set("gain_db must be 0 under the adaptive gain, got {f}", .{Number{ .value = options.gain_db }});
            return .arg;
        },
        .constant => .{ .constant = gain.Db.fromValue(options.gain_db) orelse {
            const allowed: Range = .{ .min = gain.Db.min.db, .max = gain.Db.max.db };
            common.thread_error.set("gain_db must be {f}, got {f}", .{ allowed, Number{ .value = options.gain_db, .outside = allowed } });
            return .arg;
        } },
    };
    const r = allocator.create(Handle) catch return nomem(&common.thread_error);
    r.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .b = undefined, .run = undefined };
    const read = c_phb.readPreparedBundle(Status, r.arena.allocator(), bytes, &common.thread_error, &r.b);
    if (read != .ok) {
        discard(r);
        return read;
    }
    r.run = engine_run.Run.create(allocator, &r.b.scenario, .{
        .seed = options.seed,
        .workers = options.workers,
        .noise = noise,
        .gain = setting,
    }, .{}) catch |e| {
        common.thread_error.set("cannot create the run: {s}", .{engine_run.reason(e)});
        discard(r);
        return switch (e) {
            error.NoSamples => .bundle,
            error.OutOfMemory => .nomem,
            error.ThreadSpawnFailed => .internal,
        };
    };
    dst.* = r;
    return .ok;
}

pub fn pharos_run_info_get(r: ?*const Handle, out: ?*Info) callconv(.c) Status {
    const run = (r orelse return .arg).run;
    const o = out orelse return .arg;
    const info = run.info();
    o.* = .{
        .format_bits = info.samples.format.bitsPerComponent(),
        .sample_rate_hz = info.samples.sample_rate.hz(),
        .center_hz = info.samples.center.hz,
        .samples_per_epoch = info.samples_per_epoch,
        .workers = info.workers,
        .bytes_per_epoch = info.bytes_per_epoch,
        .total_epochs = info.span.epochs,
        .start_gps_ms = info.span.start.ms,
        .start_gps_sub_ms = info.span.start.sub_ms,
        .leap_change_gps_ms = if (info.span.leap_change) |t| t.ms else 0,
        .leap_seconds = info.span.leap_seconds,
        .leap_seconds_after = info.span.leap_seconds_after,
    };
    return .ok;
}

pub fn pharos_run_pull(r: ?*Handle, buf: ?[*]u8, cap: usize, max_epochs: u32, out: ?*Block) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.clear();
    const o = out orelse return .arg;
    const bytes = (buf orelse return .arg)[0..cap];
    const block = h.run.pull(bytes, max_epochs) catch |e| {
        switch (e) {
            error.InvalidBatchSize => h.err.set("max_epochs must be at least 1, got 0", .{}),
            error.BufferTooSmall => h.err.set("the buffer must hold at least {d} bytes, one epoch, got {d}", .{ h.run.info().bytes_per_epoch, cap }),
        }
        return .arg;
    };
    for (block.applied, 0..) |a, i| h.applied[i] = .{ .epoch = a.epoch.ms, .command = c_command.toC(a.command) };
    const status: Status = if (block.failure) |e| generationFailed(h, e) else if (block.epochs == 0) .end else .ok;
    o.* = .{
        .epoch_first = block.epoch_first.ms,
        .epochs = block.epochs,
        .bytes = block.bytes,
        .clipped = block.clipped,
        .applied = &h.applied,
        .applied_count = block.applied.len,
    };
    return status;
}

pub fn pharos_run_seek(r: ?*Handle, epoch: u64) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.clear();
    h.run.seek(.{ .ms = epoch }) catch |e| switch (e) {
        error.EpochOutOfRange => {
            h.err.set("epoch must be at most {d}, got {d}", .{ h.run.info().span.epochs, epoch });
            return .arg;
        },
        error.AdaptiveGain => {
            h.err.set("seeking needs a constant gain: {s}", .{engine_run.reason(e)});
            return .arg;
        },
        error.CommandsApplied => {
            h.err.set("seeking to epoch {d} is refused: {s}", .{ epoch, engine_run.reason(e) });
            return .arg;
        },
        else => |failure| return generationFailed(h, failure),
    };
    return .ok;
}

pub fn pharos_run_submit(r: ?*Handle, c: ?*const c_command.Command) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.clear();
    const cmd = c_command.decode((c orelse return .arg).*, &h.err) orelse return .arg;
    h.run.submit(cmd) catch |e| switch (e) {
        error.TooManyPending => {
            h.err.set("the command queue holds {d} pending commands: pull, then submit again", .{commands.capacity});
            return .busy;
        },
        error.EpochPassed, error.InvalidValue => |rejection| return c_command.rejected(Status, &h.err, rejection),
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
    h.err.clear();
    const fields = if (f) |given| given.* else ManifestFields{};
    inline for (@typeInfo(ManifestFields).@"struct".field_names) |name| {
        if (!std.unicode.utf8ValidateSlice(span(@field(fields, name)))) {
            h.err.set("{s} is not UTF-8", .{name});
            return .arg;
        }
    }
    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    manifest.write(&text.writer, &h.b, h.run, .{
        .start_time_iso = span(fields.start_time_iso),
        .run_id = span(fields.run_id),
        .output_path = span(fields.output_path),
    }) catch return nomem(&h.err);
    return copyBytes(text.written(), buf, cap, len);
}

pub fn pharos_run_tag_text(r: ?*Handle, buf: ?[*]u8, cap: usize, len: ?*usize) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.clear();
    var buffer: [tag.max_len]u8 = undefined;
    const text = tag.text(&buffer, h.run.info().samples, h.run.entryTime()) orelse {
        h.err.set("the .tag format has no {s} format", .{h.run.info().samples.format.name()});
        return .arg;
    };
    return copyBytes(text, buf, cap, len);
}

pub fn pharos_run_to_file(r: ?*Handle, path: ?[*:0]const u8, bytes_written: ?*u64) callconv(.c) Status {
    const h = r orelse return .arg;
    h.err.clear();
    const p = std.mem.span(path orelse return .arg);
    var threaded: Io.Threaded = .init_single_threaded;
    const written = sink.writeRun(allocator, threaded.io(), p, h.run, engine_run.eventCheckpoint(h.run), dropEvents) catch |e| {
        if (bytes_written) |b| b.* = 0;
        if (e == error.OutOfMemory) return nomem(&h.err);
        return cannotWrite(h, p, e);
    };
    if (bytes_written) |b| b.* = written.bytes_on_file;
    if (written.write_failure) |e| return cannotWrite(h, p, e);
    if (written.failure) |e| return generationFailed(h, e);
    return .ok;
}

pub fn pharos_run_error(r: ?*const Handle) callconv(.c) [*:0]const u8 {
    return if (r) |h| h.err.cstr() else "";
}

pub fn pharos_run_destroy(r: ?*Handle) callconv(.c) void {
    const h = r orelse return;
    h.run.destroy();
    discard(h);
}

fn discard(r: *Handle) void {
    r.arena.deinit();
    allocator.destroy(r);
}

fn generationFailed(h: *Handle, e: engine_run.GenerationError) Status {
    const status: Status = switch (e) {
        error.OutOfMemory => return nomem(&h.err),
        error.Internal => .internal,
    };
    h.err.set("epoch {d} of {d} could not be generated: {s}", .{ h.run.status().epoch.ms, h.run.info().span.epochs, engine_run.reason(e) });
    return status;
}

fn span(text: ?[*:0]const u8) []const u8 {
    return if (text) |p| std.mem.span(p) else "";
}

fn cannotWrite(h: *Handle, path: []const u8, e: anyerror) Status {
    var short: [c_buffers.elided_len]u8 = undefined;
    h.err.set("cannot write {f}: {f}", .{ Escaped{ .text = c_buffers.elide(&short, path) }, FileError{ .e = e } });
    return .io;
}

fn dropEvents(queued: usize, run: *engine_run.Run, _: engine_run.Block) void {
    engine_run.discardEventsAfter(run, queued);
}

fn copyBytes(bytes: []const u8, buffer: ?[*]u8, capacity: usize, length: ?*usize) Status {
    if (length) |out| out.* = bytes.len;
    const dst = buffer orelse return .arg;
    if (bytes.len > capacity) return .arg;
    @memcpy(dst[0..bytes.len], bytes);
    return .ok;
}
