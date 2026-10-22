const std = @import("std");
const diagnostics = @import("base/diagnostics");
const header = @import("base/cache/header");
const codec = @import("base/cache/codec");
const derive = @import("phb/derive");
const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");
const signal_payload = @import("domain/signals/payload");
const publications = @import("simulation/model/publications");
const prepared = @import("simulation/model/prepared_messages");
const systems = @import("simulation/model/systems");
const policy = @import("simulation/model/message_policy");
const File = @import("phb/model/file").File;
const PreparedBundle = @import("phb/prepared").PreparedBundle;
const ServicePlan = @import("simulation/model/services").ServicePlan;

/// All returned slices borrow the caller's arena. The input bytes may be released after this call.
pub fn decodeFile(arena: std.mem.Allocator, bytes: []const u8, scope: diagnostics.Scope) diagnostics.InputError!File {
    try header.check(bytes, .phb, scope);
    var reader: codec.Reader = .{ .bytes = bytes, .arena = arena, .pos = header.header_len };
    const file = reader.decode(File) catch |err| return codec.refuse(scope, err, reader.failure_at orelse reader.pos);
    if (reader.pos != bytes.len) return scope.fail(.cache_trailing_bytes, .{ .byte_offset = reader.pos }, "the file carries bytes after the bundle", .{});
    try readReferenceIndices(&file, scope);
    return file;
}

pub fn read(arena: std.mem.Allocator, bytes: []const u8, scope: diagnostics.Scope) diagnostics.InputError!PreparedBundle {
    const file = try decodeFile(arena, bytes, scope);
    const contents = try derive.projectContents(arena, &file);
    const messages = if (file.config.samples != null) try prepareMessages(arena, &file) else null;
    return .{ .scenario = try derive.build(arena, &file, contents, messages), .display = .fromFile(&file) };
}

fn index(scope: diagnostics.Scope, pool_len: usize, value: u32, comptime path_fmt: []const u8, args: anytype) diagnostics.InputError!void {
    if (value < pool_len) return;
    var at = scope;
    at.path = try scope.diags.arena.print(path_fmt, args);
    return at.fail(.cache_reference, null, "record index {d} is outside a pool of {d} records", .{ value, pool_len });
}

fn scaleIndex(scope: diagnostics.Scope, count: usize, choice: systems.ScaleChoice, path: []const u8) diagnostics.InputError!void {
    switch (choice) {
        .record => |value| try index(scope, count, value, "{s}", .{path}),
        .zero => {},
    }
}

fn utcIndex(scope: diagnostics.Scope, count: usize, choice: systems.UtcChoice, path: []const u8) diagnostics.InputError!void {
    switch (choice) {
        .record => |value| try index(scope, count, value, "{s}", .{path}),
        .derived => |value| {
            try index(scope, count, value.utc, "{s}.utc", .{path});
            try scaleIndex(scope, count, value.donor_scale, path);
            try scaleIndex(scope, count, value.bds_scale, path);
        },
    }
}

fn eopIndex(scope: diagnostics.Scope, count: usize, choice: systems.EopChoice, path: []const u8) diagnostics.InputError!void {
    switch (choice) {
        .record => |value| try index(scope, count, value, "{s}", .{path}),
        .zero => {},
    }
}

// These are representation bounds at the first use of stored indexes, not a semantic check of pack's choices.
fn readReferenceIndices(file: *const File, scope: diagnostics.Scope) diagnostics.InputError!void {
    for (file.plan.timelines, 0..) |legs, timeline| for (legs, 0..) |leg, i| {
        const binding = leg.binding orelse continue;
        switch (binding.reference) {
            .kepler => |value| try index(scope, file.ephemerides.kepler.len, value, "plan.timelines[{d}][{d}].reference", .{ timeline, i }),
            .glonass => |value| try index(scope, file.ephemerides.glonass.len, value, "plan.timelines[{d}][{d}].reference", .{ timeline, i }),
        }
        for (std.enums.values(records.NavSource)) |source| if (binding.sources.get(source)) |value| try index(scope, file.ephemerides.kepler.len, value, "plan.timelines[{d}][{d}].sources.{s}", .{ timeline, i, @tagName(source) });
    };
    const offsets = file.systems.records.time_offsets.len;
    const eops = file.systems.records.eops.len;
    for (gnss_types.System.all) |system| try scaleIndex(scope, offsets, file.systems.scales.get(system), "systems.scales");
    for (file.systems.gps) |entry| {
        if (entry.value.lnav_utc) |choice| try utcIndex(scope, offsets, choice, "systems.gps.lnav_utc");
        if (entry.value.cnav_utc) |choice| try utcIndex(scope, offsets, choice, "systems.gps.cnav_utc");
        if (entry.value.eop) |choice| try eopIndex(scope, eops, choice, "systems.gps.eop");
        for (entry.value.ggto) |choice| if (choice) |value| try index(scope, offsets, value.record, "systems.gps.ggto", .{});
    }
    for (file.systems.galileo) |entry| {
        if (entry.value.utc) |choice| try utcIndex(scope, offsets, choice, "systems.galileo.utc");
        if (entry.value.ggto) |value| try index(scope, offsets, value, "systems.galileo.ggto", .{});
    }
    for (file.systems.bds) |entry| {
        if (entry.value.d1d2_utc) |choice| try utcIndex(scope, offsets, choice, "systems.bds.d1d2_utc");
        if (entry.value.bcnav_utc) |choice| try utcIndex(scope, offsets, choice, "systems.bds.bcnav_utc");
        if (entry.value.eop) |choice| try eopIndex(scope, eops, choice, "systems.bds.eop");
        for (entry.value.offsets) |choice| if (choice) |value| try index(scope, offsets, value, "systems.bds.offsets", .{});
    }
    for (file.systems.glonass) |entry| {
        if (entry.value.utc) |value| try index(scope, offsets, value, "systems.glonass.utc", .{});
        if (entry.value.gps) |value| try index(scope, offsets, value, "systems.glonass.gps", .{});
        if (entry.value.eop) |choice| try eopIndex(scope, eops, choice, "systems.glonass.eop");
    }
}

fn prepareMessages(arena: std.mem.Allocator, file: *const File) std.mem.Allocator.Error!prepared.PreparedMessages {
    const start = file.config.start;
    const carried = signal_payload.at(start);
    const services = ServicePlan.init(&file.config, &file.publications, &carried, file.precise != null);
    const declarations = try publications.Prepared.init(arena, file.publications, policy.needed(file.config.signals, services, &carried), start);
    const almanacs = prepared.Almanacs.init(&file.almanacs.?, &declarations.configuration);
    const broadcast = file.config.ionosphere.ready.broadcast;
    var messages: systems.Systems = .{ .start = start };
    const gps = try arena.alloc(systems.Entry(systems.Gps), file.systems.gps.len);
    for (gps, file.systems.gps) |*entry, choice| entry.* = .{ .from_ms = choice.from_ms, .value = systems.projectGps(&file.systems.records, choice.value, start.addMs(@intCast(choice.from_ms)), file.leap, &broadcast) };
    messages.gps = gps;
    const galileo = try arena.alloc(systems.Entry(systems.Value(.gal)), file.systems.galileo.len);
    for (galileo, file.systems.galileo) |*entry, choice| entry.* = .{ .from_ms = choice.from_ms, .value = systems.projectGalileo(&file.systems.records, choice.value, start.addMs(@intCast(choice.from_ms)), file.leap, &broadcast) };
    messages.galileo = galileo;
    const bds = try arena.alloc(systems.Entry(systems.Bds), file.systems.bds.len);
    for (bds, file.systems.bds) |*entry, choice| entry.* = .{ .from_ms = choice.from_ms, .value = systems.projectBds(&file.systems.records, choice.value, start.addMs(@intCast(choice.from_ms)), file.leap, &broadcast) };
    messages.bds = bds;
    const glonass = try arena.alloc(systems.Entry(systems.Value(.glo)), file.systems.glonass.len);
    for (glonass, file.systems.glonass) |*entry, choice| entry.* = .{ .from_ms = choice.from_ms, .value = systems.projectGlonass(&file.systems.records, choice.value, file.almanacs.?.glonass_day.?, start.addMs(@intCast(choice.from_ms)), file.leap) };
    messages.glonass = glonass;
    return .{ .publications = declarations, .almanacs = almanacs, .systems = messages };
}
