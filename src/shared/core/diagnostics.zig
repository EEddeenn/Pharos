const std = @import("std");

pub const InputError = error{ OutOfMemory, InvalidInput };
pub const LoadError = InputError || error{IoFailed};
pub const Position = struct { line: u32, column: u32 = 0 };

pub const Severity = enum(u32) { err = 0, warning = 1 };

pub const Code = enum(u16) {
    invalid_json = 0,
    wrong_type = 1,
    missing_field = 2,
    unknown_key = 3,
    unknown_name = 4,
    out_of_range = 5,
    duplicate = 6,
    odd_sample_count = 7,
    sample_rate_rounded = 8,
    band_excluded = 9,
    no_signal = 10,
    invalid_segment = 11,
    no_output = 12,
    no_effect = 13,
    implausible_record = 14,
    unfit_record = 15,
    center_rounded = 16,
    no_record = 17,
    invalid_format = 18,
    io_error = 19,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    path: []const u8,
    source: []const u8 = "",
    position: ?Position = null,
    message: []const u8,

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.source.len > 0) try w.print("{f}", .{Escaped{ .text = self.source }});
        if (self.position) |position| {
            if (self.source.len > 0) try w.print(":{d}", .{position.line}) else try w.print("line {d}", .{position.line});
            if (position.column > 0) try w.print(":{d}", .{position.column});
        }
        if (self.source.len > 0 or self.position != null) try w.writeAll(": ");
        if (self.path.len > 0) try w.print("{s}: ", .{self.path});
        try w.writeAll(self.message);
    }
};

/// A text of the input or of a caller as a path or a message quotes it: a control character as its JSON escape, so
/// that no key or name cuts the C string of a message, and bytes that are not UTF-8 as U+FFFD, so that it is UTF-8.
pub const Escaped = struct {
    text: []const u8,

    pub fn format(self: Escaped, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var start: usize = 0;
        for (self.text, 0..) |c, i| if (c < 0x20) {
            try w.print("{f}\\u{x:0>4}", .{ std.unicode.fmtUtf8(self.text[start..i]), c });
            start = i + 1;
        };
        try w.print("{f}", .{std.unicode.fmtUtf8(self.text[start..])});
    }
};

pub const Scope = struct {
    diags: *Diagnostics,
    source: []const u8 = "",
    path: []const u8 = "",

    pub fn err(self: Scope, code: Code, position: ?Position, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.diags.addAt(.err, code, self.source, self.path, position, fmt, args);
    }

    pub fn warn(self: Scope, code: Code, position: ?Position, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.diags.addAt(.warning, code, self.source, self.path, position, fmt, args);
    }

    pub fn fail(self: Scope, code: Code, position: ?Position, comptime fmt: []const u8, args: anytype) InputError {
        self.err(code, position, fmt, args) catch return error.OutOfMemory;
        return error.InvalidInput;
    }
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    source: []const u8 = "",
    items: std.ArrayList(Diagnostic) = .empty,
    errors: usize = 0,

    pub fn init(arena: std.mem.Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    fn add(self: *Diagnostics, severity: Severity, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.addAt(severity, code, self.source, path, null, fmt, args);
    }

    fn addAt(self: *Diagnostics, severity: Severity, code: Code, source: []const u8, path: []const u8, position: ?Position, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const message = try self.arena.print(fmt, args);
        try self.items.append(self.arena, .{ .severity = severity, .code = code, .path = path, .source = source, .position = position, .message = message });
        if (severity == .err) self.errors += 1;
    }

    pub fn forSource(self: *Diagnostics, source: []const u8) Scope {
        return .{ .diags = self, .source = source };
    }

    pub fn err(self: *Diagnostics, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.add(.err, code, path, fmt, args);
    }

    pub fn warn(self: *Diagnostics, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.add(.warning, code, path, fmt, args);
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        return self.errors != 0;
    }

    pub fn slice(self: *const Diagnostics) []const Diagnostic {
        return self.items.items;
    }

    pub fn firstError(self: *const Diagnostics) ?Diagnostic {
        for (self.items.items) |d| if (d.severity == .err) return d;
        return null;
    }
};
