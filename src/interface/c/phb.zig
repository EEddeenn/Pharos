const std = @import("std");
const diagnostic_types = @import("base/diagnostics");
const c_buffers = @import("interface/c/buffers");
const prepared_bundle = @import("phb/prepared");
const phb_read = @import("phb/read");
const status = @import("interface/c/status");
const Diagnostics = diagnostic_types.Diagnostics;
const ErrorBuffer = c_buffers.ErrorBuffer;

pub fn readPreparedBundle(comptime S: type, arena: std.mem.Allocator, bytes: []const u8, err: *ErrorBuffer, out: *prepared_bundle.PreparedBundle) S {
    var diags = Diagnostics{ .arena = arena };
    out.* = phb_read.read(arena, bytes, diags.forSource("")) catch |e| {
        if (e == error.OutOfMemory) return status.nomem(S, err);
        if (diags.firstError()) |diagnostic| err.set("{f}", .{diagnostic});
        return .bundle;
    };
    return .ok;
}
