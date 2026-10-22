const std = @import("std");
const sources = @import("products/pack/input/sources");
const diagnostic_types = @import("base/diagnostics");
const c_diagnostics = @import("interface/c/diagnostics");
const c_buffers = @import("interface/c/buffers");
const request_reader = @import("products/pack/input/scenario/read");
const phb_read = @import("phb/read");
const phb_write = @import("phb/write");
const target = @import("base/target");
const assemble = @import("products/pack/pipeline");
const angles = @import("base/math/angles");
const Io = std.Io;
const ByteView = c_buffers.ByteView;
const DiagnosticView = c_diagnostics.DiagnosticView;
const Covered = @import("products/pack/planning/coverage").Covered;
const Config = @import("simulation/model/config").Config;
const Span = @import("simulation/model/prepared_scenario").Span;
const Diagnostics = diagnostic_types.Diagnostics;
const common = @import("products/pack/c_api/context").Context;
const allocator = common.allocator;
const Status = common.Status;
const ErrorBuffer = common.ErrorBuffer;
const nomem = common.nomem;

pub const Diag = c_diagnostics.Diag;

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
    arena: std.heap.ArenaAllocator,
    entries: ?[]const Coverage = null,
    c_diags: []Diag = &.{},
};

pub const CoverageView = extern struct {
    data: ?[*]const Coverage = null,
    len: usize = 0,
};

pub const unavailable: []const []const u8 = if (target.has_file_system) &.{} else &.{"pharos_pack_create"};

pub fn pharos_pack_create(json: ?[*]const u8, len: usize, base_dir: ?[*:0]const u8, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const o = out orelse return .arg;
    o.* = null;
    const text = (json orelse return .arg)[0..len];
    var threaded: Io.Threaded = .init_single_threaded;
    return create(text, .{ .dir = .{ .io = threaded.io(), .base = if (base_dir) |d| std.mem.span(d) else null } }, o);
}

pub fn pharos_pack_create_from_memory(json: ?[*]const u8, len: usize, files: ?[*]const File, count: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const o = out orelse return .arg;
    o.* = null;
    const text = (json orelse return .arg)[0..len];
    const entries: []const File = if (count == 0) &.{} else (files orelse return .arg)[0..count];
    const table = allocator.alloc(sources.File, count) catch return nomem(&common.thread_error);
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
    }
    return create(text, .{ .memory = table }, o);
}

pub fn pharos_pack_describe_nav(file: ?*const File, out: ?*?*NavDescription) callconv(.c) Status {
    common.thread_error.clear();
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
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var diags: Diagnostics = .{ .arena = scratch.allocator() };
    var status: Status = .ok;
    const covered: ?[]const Covered = assemble.describe(scratch.allocator(), .{ .name = std.mem.span(name), .bytes = bytes[0..f.len] }, &diags) catch |e| refused: {
        if (e == error.OutOfMemory) return nomem(&common.thread_error);
        status = if (e == error.InvalidInput) .input else .io;
        break :refused null;
    };
    const description = allocator.create(NavDescription) catch return nomem(&common.thread_error);
    description.* = .{ .arena = .init(allocator) };
    const retained = description.arena.allocator();
    description.c_diags = c_diagnostics.copy(retained, diags.slice()) catch {
        pharos_pack_nav_destroy(description);
        return nomem(&common.thread_error);
    };
    if (covered) |coverage| {
        const entries = retained.alloc(Coverage, coverage.len) catch {
            pharos_pack_nav_destroy(description);
            return nomem(&common.thread_error);
        };
        for (coverage, entries) |c, *o| o.* = .{
            .system = @backingInt(c.system),
            .leap_seconds = c.leap_seconds,
            .satellites = c.satellites.bits,
            .from_gps_ms = c.from.ms,
            .until_gps_ms = c.until.ms,
        };
        description.entries = entries;
    }
    dst.* = description;
    return status;
}

pub fn pharos_pack_nav_coverage(description: ?*const NavDescription, out: ?*CoverageView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const d = description orelse return .arg;
    const entries = d.entries orelse return .arg;
    dst.* = .{ .data = if (entries.len == 0) null else entries.ptr, .len = entries.len };
    return .ok;
}

pub fn pharos_pack_nav_diagnostics(description: ?*const NavDescription, out: ?*DiagnosticView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const d = description orelse return .arg;
    dst.* = .fromSlice(d.c_diags);
    return .ok;
}

pub fn pharos_pack_nav_destroy(description: ?*NavDescription) callconv(.c) void {
    const d = description orelse return;
    d.arena.deinit();
    allocator.destroy(d);
}

pub fn pharos_pack_diagnostics(p: ?*const Handle, out: ?*DiagnosticView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const h = p orelse return .arg;
    dst.* = .fromSlice(h.c_diags);
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
    common.thread_error.clear();
    const dst = out orelse return .arg;
    const data = (bytes orelse return .arg)[0..len];
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diags: Diagnostics = .{ .arena = arena.allocator() };
    const file = phb_read.decodeFile(arena.allocator(), data, diags.forSource("")) catch |e| {
        if (e == error.OutOfMemory) return nomem(&common.thread_error);
        if (diags.firstError()) |diagnostic| common.thread_error.set("{f}", .{diagnostic});
        return .bundle;
    };
    dst.* = summaryOf(&file.config, .of(file.config.start, file.config.duration_ms, file.leap));
    return .ok;
}

pub fn pharos_pack_bytes(p: ?*Handle, out: ?*ByteView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const h = p orelse return .arg;
    const result = h.result orelse return noBundle(h);
    dst.* = .fromSlice(result.bytes);
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

fn create(json: []const u8, source: sources.Source, out: *?*Handle) Status {
    const p = allocator.create(Handle) catch return nomem(&common.thread_error);
    p.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var diags = Diagnostics{ .arena = arena };
    var status: Status = .ok;
    const assembled: ?assemble.Assembled = assembleText(arena, source, json, &diags) catch |e| blk: {
        status = switch (e) {
            error.OutOfMemory => return nomemDestroy(p),
            error.InvalidInput => .input,
            error.IoFailed => .io,
        };
        if (diags.firstError()) |d| p.err.set("{f}", .{d});
        break :blk null;
    };
    const retained = p.arena.allocator();
    p.c_diags = c_diagnostics.copy(retained, diags.slice()) catch return nomemDestroy(p);
    if (assembled) |a| {
        var text_out: Io.Writer.Allocating = .init(retained);
        phb_write.write(&text_out.writer, &a.file) catch return nomemDestroy(p);
        p.result = .{ .bytes = text_out.written(), .summary = summaryOf(&a.file.config, .of(a.file.config.start, a.file.config.duration_ms, a.file.leap)) };
    }
    out.* = p;
    return status;
}

fn assembleText(arena: std.mem.Allocator, source: sources.Source, json: []const u8, diags: *Diagnostics) diagnostic_types.LoadError!assemble.Assembled {
    const request = try request_reader.readRequest(arena, json, diags);
    return assemble.assemble(arena, source, &request, diags);
}

fn summaryOf(scenario: *const Config, span: Span) Info {
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
        .elevation_mask_deg = angles.rad2deg(scenario.elevation_mask_rad),
        .observation_interval_ms = if (scenario.observation) |o| o.interval_ms else 0,
        .position_interval_ms = if (scenario.position) |p| p.interval_ms else 0,
        .position_format = if (scenario.position) |p| @backingInt(p.format) else 0,
    };
}

fn noBundle(h: *Handle) Status {
    h.err.set("the object holds no bundle: its scenario had errors or a file failed to load", .{});
    return .arg;
}

fn nomemDestroy(p: *Handle) Status {
    pharos_pack_destroy(p);
    return nomem(&common.thread_error);
}
