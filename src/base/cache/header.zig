const std = @import("std");
const diagnostics = @import("base/diagnostics");
const source_digest = @import("build_info").source_digest;

pub const Kind = enum { phb, pht };
pub const header_len: usize = 16;

const version: u32 = 2;

pub fn write(w: *std.Io.Writer, comptime kind: Kind) std.Io.Writer.Error!void {
    try w.writeAll(magic(kind));
    try w.writeInt(u32, version, .little);
    try w.writeInt(u64, source_digest, .little);
}

pub fn check(bytes: []const u8, comptime kind: Kind, scope: diagnostics.Scope) diagnostics.InputError!void {
    const name: []const u8 = switch (kind) {
        .phb => "bundle",
        .pht => "trajectory",
    };
    const regenerate: []const u8 = switch (kind) {
        .phb => "re-run pharos-pack on the scenario",
        .pht => "re-run pharos-traj build or pharos-traj static to regenerate the trajectory",
    };
    if (bytes.len < header_len) return scope.fail(.cache_truncated, .{ .byte_offset = bytes.len }, "the file ends inside the {s} header: it is truncated", .{name});
    if (!std.mem.eql(u8, bytes[0..4], magic(kind))) return scope.fail(.cache_header, .{ .byte_offset = 0 }, "the file does not begin with a {s} header; {s}", .{ name, regenerate });
    if (std.mem.readInt(u32, bytes[4..][0..4], .little) != version) return scope.fail(.cache_header, .{ .byte_offset = 4 }, "the {s} header version is not this build's; {s}", .{ name, regenerate });
    const packed_digest = std.mem.readInt(u64, bytes[8..][0..8], .little);
    if (packed_digest != source_digest) return scope.fail(.cache_source_mismatch, .{ .byte_offset = 8 }, "the {s} was written by a Pharos built from other sources ({x:0>16}); this build's sources are {x:0>16}; {s}", .{ name, packed_digest, source_digest, regenerate });
}

fn magic(comptime kind: Kind) *const [4]u8 {
    return switch (kind) {
        .phb => "PHB1",
        .pht => "PHT1",
    };
}
