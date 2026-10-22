const std = @import("std");

pub const Source = struct { name: []const u8, sha256_hex: []const u8 };

pub const Blob = struct {
    bytes: []const u8,
    size: usize,
    sha256_hex: []const u8,
    source: ?Source = null,
};

pub fn blob(comptime bytes: []const u8, comptime size: usize, sha256_hex: []const u8) Blob {
    comptime std.debug.assert(bytes.len == size);
    return .{ .bytes = bytes, .size = size, .sha256_hex = sha256_hex };
}

pub fn derived(comptime bytes: []const u8, comptime size: usize, sha256_hex: []const u8, source: Source) Blob {
    comptime std.debug.assert(bytes.len == size);
    return .{ .bytes = bytes, .size = size, .sha256_hex = sha256_hex, .source = source };
}
