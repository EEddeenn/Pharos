const std = @import("std");
const diagnostics = @import("base/diagnostics");
const Escaped = diagnostics.Escaped;
const Diagnostic = diagnostics.Diagnostic;

pub const LocationKind = enum(u32) { none = 0, text = 1, byte_offset = 2 };

pub const Diag = extern struct {
    code: u32,
    severity: u32,
    source: [*:0]const u8,
    path: [*:0]const u8,
    location_kind: u32,
    line: u32,
    column: u32,
    byte_offset: u64,
    message: [*:0]const u8,
};

pub const DiagnosticView = extern struct {
    data: ?[*]const Diag = null,
    len: usize = 0,

    pub fn fromSlice(items: []const Diag) DiagnosticView {
        return .{ .data = if (items.len == 0) null else items.ptr, .len = items.len };
    }
};

/// The copied records and strings borrow the caller's arena.
pub fn copy(arena: std.mem.Allocator, list: []const Diagnostic) error{OutOfMemory}![]Diag {
    const out = try arena.alloc(Diag, list.len);
    for (out, list) |*c, d| {
        c.* = .{
            .code = @backingInt(d.code),
            .severity = @backingInt(d.severity),
            .source = try arena.printSentinel("{f}", .{Escaped{ .text = d.source }}, 0),
            .path = try arena.dupeSentinel(u8, d.path, 0),
            .location_kind = @backingInt(LocationKind.none),
            .line = 0,
            .column = 0,
            .byte_offset = 0,
            .message = try arena.dupeSentinel(u8, d.message, 0),
        };
        if (d.location) |location| switch (location) {
            .text => |at| {
                c.location_kind = @backingInt(LocationKind.text);
                c.line = at.line;
                c.column = at.column;
            },
            .byte_offset => |offset| {
                c.location_kind = @backingInt(LocationKind.byte_offset);
                c.byte_offset = offset;
            },
        };
    }
    return out;
}
