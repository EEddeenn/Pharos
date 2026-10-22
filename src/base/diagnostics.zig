const std = @import("std");

pub const InputError = error{ OutOfMemory, InvalidInput };
pub const LoadError = InputError || error{IoFailed};

pub const Severity = enum(u32) { err = 0, warning = 1, note = 2 };

pub const Category = enum(u8) { source, syntax, structure, value, preparation, cache };

pub const Code = enum(u16) {
    io_error = 100,
    ignored_records = 101,
    invalid_json = 200,
    wrong_type = 300,
    missing_field = 301,
    unknown_key = 302,
    unknown_name = 303,
    duplicate = 304,
    invalid_format = 305,
    out_of_range = 400,
    odd_sample_count = 401,
    invalid_segment = 402,
    implausible_record = 403,
    sample_rate_rounded = 500,
    center_rounded = 501,
    band_excluded = 502,
    no_signal = 503,
    no_output = 504,
    no_effect = 505,
    unfit_record = 506,
    no_record = 507,
    group_delay_assumed = 508,
    ionosphere_rounded = 509,
    system_data_derived = 510,
    system_data_assumed = 511,
    cache_header = 600,
    cache_source_mismatch = 601,
    cache_truncated = 602,
    cache_invalid_value = 603,
    cache_trailing_bytes = 604,
    cache_reference = 605,

    pub fn category(self: Code) Category {
        return switch (self) {
            .io_error, .ignored_records => .source,
            .invalid_json => .syntax,
            .wrong_type, .missing_field, .unknown_key, .unknown_name, .duplicate, .invalid_format => .structure,
            .out_of_range, .odd_sample_count, .invalid_segment, .implausible_record => .value,
            .sample_rate_rounded, .center_rounded, .band_excluded, .no_signal, .no_output, .no_effect, .unfit_record, .no_record, .group_delay_assumed, .ionosphere_rounded, .system_data_derived, .system_data_assumed => .preparation,
            .cache_header, .cache_source_mismatch, .cache_truncated, .cache_invalid_value, .cache_trailing_bytes, .cache_reference => .cache,
        };
    }
};

pub const Location = union(enum) {
    text: Text,
    byte_offset: u64,

    pub const Text = struct { line: u32, column: u32 = 0 };
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    path: []const u8,
    source: []const u8 = "",
    location: ?Location = null,
    message: []const u8,

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.source.len > 0) try w.print("{f}", .{Escaped{ .text = self.source }});
        if (self.location) |location| switch (location) {
            .text => |at| {
                if (self.source.len > 0) try w.print(":{d}", .{at.line}) else try w.print("line {d}", .{at.line});
                if (at.column > 0) try w.print(":{d}", .{at.column});
            },
            .byte_offset => |offset| {
                if (self.source.len > 0) try w.writeAll(": ");
                try w.print("byte {d}", .{offset});
            },
        };
        if (self.source.len > 0 or self.location != null) try w.writeAll(": ");
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

    pub fn err(self: Scope, code: Code, location: ?Location, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.diags.addAt(.err, code, self.source, self.path, location, fmt, args);
    }

    pub fn warn(self: Scope, code: Code, location: ?Location, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.diags.addAt(.warning, code, self.source, self.path, location, fmt, args);
    }

    pub fn note(self: Scope, code: Code, location: ?Location, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.diags.addAt(.note, code, self.source, self.path, location, fmt, args);
    }

    pub fn fail(self: Scope, code: Code, location: ?Location, comptime fmt: []const u8, args: anytype) InputError {
        try self.err(code, location, fmt, args);
        return error.InvalidInput;
    }
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    source: []const u8 = "",
    items: std.ArrayList(Diagnostic) = .empty,
    errors: usize = 0,

    pub fn forSource(self: *Diagnostics, source: []const u8) Scope {
        return .{ .diags = self, .source = source };
    }

    pub fn err(self: *Diagnostics, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.add(.err, code, path, fmt, args);
    }

    pub fn warn(self: *Diagnostics, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.add(.warning, code, path, fmt, args);
    }

    pub fn note(self: *Diagnostics, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.add(.note, code, path, fmt, args);
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

    fn add(self: *Diagnostics, severity: Severity, code: Code, path: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        return self.addAt(severity, code, self.source, path, null, fmt, args);
    }

    fn addAt(self: *Diagnostics, severity: Severity, code: Code, source: []const u8, path: []const u8, location: ?Location, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const message = try self.arena.print(fmt, args);
        try self.items.append(self.arena, .{ .severity = severity, .code = code, .path = path, .source = source, .location = location, .message = message });
        if (severity == .err) self.errors += 1;
    }
};
