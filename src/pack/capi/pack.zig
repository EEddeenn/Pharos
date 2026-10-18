const std = @import("std");
const Io = std.Io;
const bundle = @import("shared").bundle;
const Diagnostics = @import("shared").core.diagnostics.Diagnostics;
const target = @import("shared").core.target;
const assemble = @import("../assemble.zig");
const nav = @import("../nav.zig");
const capi = @import("shared").capi;
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

pub const Diag = capi.Diag;

pub const File = extern struct {
    name: ?[*:0]const u8,
    bytes: ?[*]const u8,
    len: usize,
};

pub const Coverage = extern struct {
    system: u32,
    leap_seconds: i32,
    satellites: u64,
    from_gps_ms: i64,
    until_gps_ms: i64,
};

pub const Info = extern struct {
    duration_ms: u64,
    start_gps_ms: i64,
    start_gps_sub_ms: f64,
    leap_change_gps_ms: i64,
    leap_seconds: i32,
    leap_seconds_after: i32,
    has_samples: u32,
    sample_format: u32,
    sample_rate_hz: u64,
    center_hz: i64,
    elevation_mask_deg: f64,
    observation_interval_ms: u32,
    position_interval_ms: u32,
    position_format: u32,
};

const Packed = struct { bytes: []const u8, summary: Info };

pub const Handle = struct {
    arena: std.heap.ArenaAllocator,
    c_diags: []Diag = &.{},
    result: ?Packed = null,
    err: ErrorBuffer = .{},
};

pub const NavDescription = struct {
    entries: []Coverage,
};

pub fn pharos_pack_create(json: ?[*]const u8, len: usize, base_dir: ?[*:0]const u8, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const text = (json orelse return .arg)[0..len];
    var threaded: Io.Threaded = .init_single_threaded;
    return create(text, .{ .dir = .{ .io = threaded.io(), .base = if (base_dir) |d| std.mem.span(d) else null } }, o);
}

pub const unavailable: []const []const u8 = if (target.has_file_system) &.{} else &.{"pharos_pack_create"};

comptime {
    capi.exportFunctions("pharos_pack", @This());
}

pub fn pharos_pack_create_from_memory(json: ?[*]const u8, len: usize, files: ?[*]const File, count: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.begin();
    const o = out orelse return .arg;
    o.* = null;
    const text = (json orelse return .arg)[0..len];
    const entries: []const File = if (count == 0) &.{} else (files orelse return .arg)[0..count];
    const table = allocator.alloc(nav.files.File, count) catch return nomem(&common.thread_error);
    defer allocator.free(table);
    for (entries, table, 0..) |entry, *file, i| {
        const name = entry.name orelse {
            common.thread_error.set("files[{d}] has no name", .{i});
            return .arg;
        };
        const bytes = entry.bytes orelse if (entry.len == 0) "" else {
            common.thread_error.set("files[{d}] has no bytes", .{i});
            return .arg;
        };
        file.* = .{ .name = std.mem.span(name), .bytes = bytes[0..entry.len] };
        for (table[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, file.name)) {
                var short: [capi.elided_len]u8 = undefined;
                common.thread_error.set("the name {s} is given twice", .{capi.elide(&short, file.name)});
                return .arg;
            }
        }
    }
    return create(text, .{ .memory = table }, o);
}

fn create(json: []const u8, source: nav.files.Source, out: *?*Handle) Status {
    const p = allocator.create(Handle) catch return nomem(&common.thread_error);
    p.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var diags = Diagnostics.init(arena);
    var status: Status = .ok;
    const assembled: ?assemble.Assembled = assemble.assemble(arena, source, json, &diags) catch |e| switch (e) {
        error.OutOfMemory => return nomemDestroy(p),
        error.InvalidInput, error.IoFailed => blk: {
            status = if (e == error.InvalidInput) .input else .io;
            if (diags.firstError()) |d| p.err.set("{f}", .{d});
            break :blk null;
        },
    };
    const retained = p.arena.allocator();
    p.c_diags = capi.diagsOf(retained, diags.slice()) catch return nomemDestroy(p);
    if (assembled) |a| {
        var text_out: Io.Writer.Allocating = .init(retained);
        bundle.format.write(&text_out.writer, &a.bundle) catch return nomemDestroy(p);
        p.result = .{ .bytes = text_out.written(), .summary = summaryOf(&a.bundle, a.span) };
    }
    out.* = p;
    return status;
}

pub fn pharos_pack_describe_nav(file: ?*const File, out: ?*?*NavDescription) callconv(.c) Status {
    common.thread_error.begin();
    const dst = out orelse return .arg;
    dst.* = null;
    const f = file orelse return .arg;
    const name = f.name orelse {
        common.thread_error.set("the file has no name", .{});
        return .arg;
    };
    const bytes = f.bytes orelse if (f.len == 0) "" else {
        common.thread_error.set("the file has no bytes", .{});
        return .arg;
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = Diagnostics.init(arena);
    const covered = assemble.describe(arena, .{ .name = std.mem.span(name), .bytes = bytes[0..f.len] }, &diags) catch |e| switch (e) {
        error.OutOfMemory => return nomem(&common.thread_error),
        error.InvalidInput, error.IoFailed => {
            if (diags.firstError()) |d| common.thread_error.set("{f}", .{d});
            return if (e == error.InvalidInput) .input else .io;
        },
    };
    const description = allocator.create(NavDescription) catch return nomem(&common.thread_error);
    const entries = allocator.alloc(Coverage, covered.len) catch {
        allocator.destroy(description);
        return nomem(&common.thread_error);
    };
    for (covered, entries) |c, *o| o.* = .{
        .system = @backingInt(c.system),
        .leap_seconds = c.leap_seconds,
        .satellites = c.satellites.bits,
        .from_gps_ms = c.from.ms,
        .until_gps_ms = c.until.ms,
    };
    description.* = .{ .entries = entries };
    dst.* = description;
    return .ok;
}

pub fn pharos_pack_nav_coverage(description: ?*const NavDescription, out: ?*?[*]const Coverage, count: ?*usize) callconv(.c) Status {
    const d = description orelse return .arg;
    const dst = out orelse return .arg;
    const n = count orelse return .arg;
    dst.* = d.entries.ptr;
    n.* = d.entries.len;
    return .ok;
}

pub fn pharos_pack_nav_destroy(description: ?*NavDescription) callconv(.c) void {
    const d = description orelse return;
    allocator.free(d.entries);
    allocator.destroy(d);
}

pub fn pharos_pack_diag_count(p: ?*const Handle) callconv(.c) usize {
    return if (p) |h| h.c_diags.len else 0;
}

pub fn pharos_pack_diag_get(p: ?*const Handle, index: usize, out: ?*Diag) callconv(.c) Status {
    const h = p orelse return .arg;
    const o = out orelse return .arg;
    if (index >= h.c_diags.len) return .arg;
    o.* = h.c_diags[index];
    return .ok;
}

pub fn pharos_pack_has_bundle(p: ?*const Handle) callconv(.c) c_int {
    return if (p) |h| @intFromBool(h.result != null) else 0;
}

pub fn pharos_pack_info_get(p: ?*const Handle, out: ?*Info) callconv(.c) Status {
    const result = (p orelse return .arg).result orelse return .arg;
    const o = out orelse return .arg;
    o.* = result.summary;
    return .ok;
}

pub fn pharos_pack_summary_from_memory(bytes: ?[*]const u8, len: usize, out: ?*Info) callconv(.c) Status {
    common.thread_error.begin();
    const dst = out orelse return .arg;
    const data = (bytes orelse return .arg)[0..len];
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var b: bundle.Bundle = undefined;
    const status = capi.readBundle(Status, arena.allocator(), data, &common.thread_error, &b);
    if (status != .ok) return status;
    dst.* = summaryOf(&b, b.span());
    return .ok;
}

fn summaryOf(b: *const bundle.Bundle, span: bundle.Span) Info {
    const scenario = &b.scenario;
    return .{
        .duration_ms = span.epochs,
        .start_gps_ms = span.start.ms,
        .start_gps_sub_ms = span.start.sub_ms,
        .leap_change_gps_ms = if (span.leap_change) |t| t.ms else 0,
        .leap_seconds = span.leap_seconds,
        .leap_seconds_after = span.leap_seconds_after,
        .has_samples = @intFromBool(scenario.samples != null),
        .sample_format = if (scenario.samples) |s| @backingInt(s.format) else 0,
        .sample_rate_hz = if (scenario.samples) |s| s.sample_rate.hz() else 0,
        .center_hz = if (scenario.samples) |s| s.center.hz else 0,
        .elevation_mask_deg = @import("shared").core.constants.rad2deg(scenario.elevation_mask_rad),
        .observation_interval_ms = if (scenario.observation) |o| o.interval_ms else 0,
        .position_interval_ms = if (scenario.position) |p| p.interval_ms else 0,
        .position_format = if (scenario.position) |p| @backingInt(p.format) else 0,
    };
}

pub fn pharos_pack_bytes(p: ?*Handle, out: ?*?[*]const u8, len: ?*usize) callconv(.c) Status {
    const h = p orelse return .arg;
    const o = out orelse return .arg;
    const result = h.result orelse return noBundle(h);
    o.* = result.bytes.ptr;
    if (len) |l| l.* = result.bytes.len;
    return .ok;
}

pub fn pharos_pack_error(p: ?*const Handle) callconv(.c) [*:0]const u8 {
    return if (p) |h| h.err.cstr() else "";
}

pub fn pharos_pack_destroy(p: ?*Handle) callconv(.c) void {
    const h = p orelse return;
    h.arena.deinit();
    allocator.destroy(h);
}

fn noBundle(h: *Handle) Status {
    h.err.set("the object holds no bundle: its scenario had errors or a file failed to load", .{});
    return .arg;
}

fn nomemDestroy(p: *Handle) Status {
    pharos_pack_destroy(p);
    return nomem(&common.thread_error);
}
