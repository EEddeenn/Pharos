const std = @import("std");
const shared = @import("shared");
const plan = @import("../plan.zig");
const common = @import("common.zig");
const allocator = common.allocator;
const Status = common.Status;

pub const GeometryDescription = struct { bytes: []u8 };

/// The guides of a plan's coordinates and places; the plan language has no guides.
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
    _ = plan.read.parseGeometry(arena, text, &diags) catch |err| switch (err) {
        error.OutOfMemory => return common.nomem(&common.thread_error),
        error.InvalidInput => {
            if (diags.firstError()) |d| common.thread_error.set("{f}", .{d});
            return .input;
        },
    };
    const bytes = allocator.dupe(u8, "{\"guides\":[]}") catch return common.nomem(&common.thread_error);
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
