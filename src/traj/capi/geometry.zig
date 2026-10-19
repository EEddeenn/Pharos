const std = @import("std");
const shared = @import("shared");
const coord = shared.core.coord;
const plan = @import("../plan.zig");
const guide = @import("../guide.zig");
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;

pub const GeometryDescription = struct { bytes: []u8 };

const Position = struct { latitude: f64, longitude: f64 };

/// A guide as far as the plan gives it: its positions where it is whole, none where it is not.
const Drawing = struct { id: ?[]const u8, whole: bool, positions: ?[]const Position };

/// The guides of a plan, whole or being written, each in the plan's order: each piece of a whole guide's path cut
/// into `subdivisions` steps.
pub fn pharos_traj_describe_geometry(json: ?[*]const u8, len: usize, subdivisions: usize, out: ?*?*GeometryDescription) callconv(.c) Status {
    common.thread_error.begin();
    const dst = out orelse return .arg;
    dst.* = null;
    const text = (json orelse return .arg)[0..len];
    if (subdivisions == 0) {
        common.thread_error.set("subdivisions must be at least 1, got 0", .{});
        return .arg;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = shared.core.diagnostics.Diagnostics.init(arena);
    const sketch = plan.read.parseGeometry(arena, text, &diags) catch |err| switch (err) {
        error.OutOfMemory => return common.nomem(&common.thread_error),
        error.InvalidInput => {
            if (diags.firstError()) |d| common.thread_error.set("{f}", .{d});
            return .input;
        },
    };
    const drawings = arena.alloc(Drawing, sketch.guides.len) catch return common.nomem(&common.thread_error);
    for (sketch.guides, drawings) |given, *drawing| {
        drawing.* = .{ .id = given.id, .whole = false, .positions = null };
        const g = given.guide orelse continue;
        const shape = switch (guide.build(arena, sketch.places, g) catch return common.nomem(&common.thread_error)) {
            .shape => |s| s,
            .fault => continue,
        };
        const points = guide.outline(arena, shape, subdivisions) catch return common.nomem(&common.thread_error);
        const positions = arena.alloc(Position, points.len) catch return common.nomem(&common.thread_error);
        for (points, positions) |p, *position| {
            const lla = coord.ecefToLla(p);
            position.* = .{ .latitude = lla.latDeg(), .longitude = lla.lonDeg() };
        }
        drawing.* = .{ .id = given.id, .whole = true, .positions = positions };
    }
    const bytes = std.json.Stringify.valueAlloc(allocator, .{ .guides = drawings }, .{}) catch return common.nomem(&common.thread_error);
    const description = allocator.create(GeometryDescription) catch {
        allocator.free(bytes);
        return common.nomem(&common.thread_error);
    };
    description.* = .{ .bytes = bytes };
    dst.* = description;
    return .ok;
}

pub fn pharos_traj_geometry_bytes(description: ?*const GeometryDescription, out: ?*?[*]const u8, len: ?*usize) callconv(.c) Status {
    const value = description orelse return .arg;
    const dst = out orelse return .arg;
    const count = len orelse return .arg;
    dst.* = value.bytes.ptr;
    count.* = value.bytes.len;
    return .ok;
}

pub fn pharos_traj_geometry_destroy(description: ?*GeometryDescription) callconv(.c) void {
    const value = description orelse return;
    allocator.free(value.bytes);
    allocator.destroy(value);
}

comptime {
    shared.capi.exportFunctions("pharos_traj", @This());
}
