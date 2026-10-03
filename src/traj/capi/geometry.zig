const std = @import("std");
const shared = @import("shared");
const plan = @import("../plan.zig");
const inspect = @import("../inspect.zig");
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;

pub const GeometryDescription = struct { bytes: []u8 };

pub fn pharos_traj_describe_geometry(json: ?[*]const u8, len: usize, subdivisions: usize, out: ?*?*GeometryDescription) callconv(.c) Status {
    common.thread_error.begin();
    const dst = out orelse return .arg;
    dst.* = null;
    const text = (json orelse return .arg)[0..len];
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags = shared.core.diagnostics.Diagnostics.init(arena);
    const parsed = plan.read.parseGeometry(arena, text, &diags) catch |err| switch (err) {
        error.OutOfMemory => return common.nomem(&common.thread_error),
        error.InvalidInput => {
            if (diags.firstError()) |d| common.thread_error.set("{f}", .{d});
            return .input;
        },
    };
    const projected = inspect.geometry(arena, parsed, subdivisions) catch |err| switch (err) {
        error.OutOfMemory => return common.nomem(&common.thread_error),
        error.InvalidSampleCount => {
            common.thread_error.set("subdivisions must be positive and fit the geometry size, got {d}", .{subdivisions});
            return .arg;
        },
    };
    const bytes = std.json.Stringify.valueAlloc(allocator, projected, .{}) catch return common.nomem(&common.thread_error);
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
