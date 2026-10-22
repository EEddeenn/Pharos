const std = @import("std");
const diagnostics = @import("base/diagnostics");
const header = @import("base/cache/header");
const codec = @import("base/cache/codec");
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;

/// All returned slices borrow the caller's arena. The input bytes may be released after this call.
pub fn read(arena: std.mem.Allocator, bytes: []const u8, scope: diagnostics.Scope) diagnostics.InputError!Trajectory {
    try header.check(bytes, .pht, scope);
    var reader: codec.Reader = .{ .bytes = bytes, .arena = arena, .pos = header.header_len };
    const value = reader.decode(Trajectory) catch |err| return codec.refuse(scope, err, reader.failure_at orelse reader.pos);
    if (reader.pos != bytes.len) return scope.fail(.cache_trailing_bytes, .{ .byte_offset = reader.pos }, "the file carries bytes after the trajectory", .{});
    return value;
}
