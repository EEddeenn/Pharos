const std = @import("std");
const diagnostics = @import("base/diagnostics");
const geometry = @import("products/traj/output/geometry");
const ByteView = @import("interface/c/buffers").ByteView;
const context = @import("products/traj/c_api/context").Context;
const allocator = context.allocator;
const Status = context.Status;

pub const GeometryDescription = struct { bytes: []u8 };

pub fn pharos_traj_describe_geometry(json: ?[*]const u8, len: usize, subdivisions: usize, out: ?*?*GeometryDescription) callconv(.c) Status {
    context.thread_error.clear();
    const dst = out orelse return .arg;
    dst.* = null;
    const text = (json orelse return .arg)[0..len];
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var diags: diagnostics.Diagnostics = .{ .arena = scratch.allocator() };
    const drawing = geometry.describeGeometry(scratch.allocator(), text, subdivisions, &diags) catch |e| switch (e) {
        error.OutOfMemory => return context.nomem(&context.thread_error),
        error.InvalidSubdivisions => {
            context.thread_error.set("subdivisions must be at least 1, got 0", .{});
            return .arg;
        },
        error.InvalidInput => {
            if (diags.firstError()) |d| context.thread_error.set("{f}", .{d});
            return .input;
        },
    };
    const bytes = std.json.Stringify.valueAlloc(allocator, drawing, .{}) catch return context.nomem(&context.thread_error);
    const description = allocator.create(GeometryDescription) catch {
        allocator.free(bytes);
        return context.nomem(&context.thread_error);
    };
    description.* = .{ .bytes = bytes };
    dst.* = description;
    return .ok;
}

pub fn pharos_traj_geometry_bytes(description: ?*const GeometryDescription, out: ?*ByteView) callconv(.c) Status {
    const dst = out orelse return .arg;
    dst.* = .{};
    const value = description orelse return .arg;
    dst.* = .fromSlice(value.bytes);
    return .ok;
}

pub fn pharos_traj_geometry_destroy(description: ?*GeometryDescription) callconv(.c) void {
    const value = description orelse return;
    allocator.free(value.bytes);
    allocator.destroy(value);
}
