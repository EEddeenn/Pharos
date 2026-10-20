const std = @import("std");
const core = @import("../core.zig");
const dictionary = core.dictionary;
const json = std.json;
const Diagnostics = core.diagnostics.Diagnostics;
const Escaped = core.diagnostics.Escaped;
const Range = @import("table.zig").Range;

const max_integer_f64 = 9.0e18;

pub const Error = std.mem.Allocator.Error;

pub const Ctx = struct {
    arena: std.mem.Allocator,
    diags: *Diagnostics,
};

pub const Node = struct {
    ctx: *const Ctx,
    value: json.Value,
    path: []const u8,

    fn wrongType(self: Node, expected: []const u8) Error!void {
        try self.ctx.diags.err(.wrong_type, self.path, "expected {s}, found {s}", .{ expected, found(self.value) });
    }

    pub fn string(self: Node) Error!?[]const u8 {
        switch (self.value) {
            .string => |s| return s,
            else => {
                try self.wrongType("a string");
                return null;
            },
        }
    }

    pub fn boolean(self: Node) Error!?bool {
        switch (self.value) {
            .bool => |b| return b,
            else => {
                try self.wrongType("a boolean");
                return null;
            },
        }
    }

    pub fn number(self: Node) Error!?f64 {
        switch (self.value) {
            .integer => |i| return @floatFromInt(i),
            .float => |f| return f,
            .number_string => |s| {
                const v = std.fmt.parseFloat(f64, s) catch std.math.inf(f64);
                if (std.math.isFinite(v)) return v;
                try self.ctx.diags.err(.out_of_range, self.path, "{s} is beyond the range of a double", .{s});
                return null;
            },
            else => {
                try self.wrongType("a number");
                return null;
            },
        }
    }

    pub fn integer(self: Node) Error!?i64 {
        const v: i64 = switch (self.value) {
            .integer => |i| i,
            .float => |f| blk: {
                if (f != @floor(f) or !std.math.isFinite(f)) {
                    try self.ctx.diags.err(.wrong_type, self.path, "expected an integer, found {f}", .{Number{ .value = f, .fraction = true }});
                    return null;
                }
                if (f < -max_integer_f64 or f > max_integer_f64) {
                    try self.ctx.diags.err(.out_of_range, self.path, "{f} does not fit an integer", .{Number{ .value = f, .outside = .{ .min = -max_integer_f64, .max = max_integer_f64 } }});
                    return null;
                }
                break :blk @intFromFloat(f);
            },
            .number_string => |s| {
                try self.ctx.diags.err(.out_of_range, self.path, "{s} does not fit an integer", .{s});
                return null;
            },
            else => {
                try self.wrongType("an integer");
                return null;
            },
        };
        return v;
    }

    pub fn array(self: Node) Error!?[]const json.Value {
        switch (self.value) {
            .array => |a| return a.items,
            else => {
                try self.wrongType("an array");
                return null;
            },
        }
    }

    pub fn object(self: Node) Error!?Object {
        switch (self.value) {
            .object => |map| return try Object.init(self, map),
            else => {
                try self.wrongType("an object");
                return null;
            },
        }
    }

    pub fn item(self: Node, i: usize, value: json.Value) Error!Node {
        return .{ .ctx = self.ctx, .value = value, .path = try element(self.ctx, self.path, i) };
    }

    pub fn word(self: Node, comptime E: type, what: []const u8) Error!?E {
        const text = try self.string() orelse return null;
        return dictionary.parse(E, text) orelse {
            try self.ctx.diags.err(.unknown_name, self.path, "unknown {s} \"{f}\"; the {s} words are {s}", .{ what, Escaped{ .text = text }, what, comptime dictionary.words(E) });
            return null;
        };
    }
};

pub const Object = struct {
    node: Node,
    map: json.ObjectMap,
    seen: []bool,

    fn init(node: Node, map: json.ObjectMap) Error!Object {
        const seen = try node.ctx.arena.alloc(bool, map.count());
        @memset(seen, false);
        return .{ .node = node, .map = map, .seen = seen };
    }

    pub fn childPath(self: Object, key: []const u8) Error![]const u8 {
        return join(self.node.ctx, self.node.path, key);
    }

    pub fn get(self: Object, key: []const u8) Error!?Node {
        return try self.entry(self.map.getIndex(key) orelse return null);
    }

    pub fn entry(self: Object, index: usize) Error!Node {
        self.seen[index] = true;
        return .{ .ctx = self.node.ctx, .value = self.map.values()[index], .path = try self.childPath(self.map.keys()[index]) };
    }

    pub fn keys(self: Object) []const []const u8 {
        return self.map.keys();
    }

    /// Every key not read is an error; `takes` lists the keys the object takes, with the first of them.
    pub fn finish(self: Object, takes: []const u8) Error!bool {
        var ok = true;
        for (self.map.keys(), self.seen) |key, was_seen| {
            if (was_seen) continue;
            try unknownKey(self.node.ctx, try self.childPath(key), if (ok) takes else null);
            ok = false;
        }
        return ok;
    }
};

pub fn unknownKey(ctx: *const Ctx, path: []const u8, takes: ?[]const u8) Error!void {
    if (takes) |keys| {
        if (keys.len == 0) return ctx.diags.err(.unknown_key, path, "unknown key; this object takes no key", .{});
        return ctx.diags.err(.unknown_key, path, "unknown key; the keys here are {s}", .{keys});
    }
    try ctx.diags.err(.unknown_key, path, "unknown key", .{});
}

/// What a JSON value is, in the words of a sentence.
pub fn found(value: json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

/// Why a JSON text did not parse, in the words of a sentence.
pub fn unparsed(e: anyerror) []const u8 {
    return switch (e) {
        error.UnexpectedEndOfInput => "the text ends before the JSON is complete",
        error.DuplicateField => "a key appears twice in one object",
        else => "invalid JSON",
    };
}

/// A floating value as a sentence writes it: four significant digits, with an exponent outside 1e-3 to 1e6; more,
/// the fewest that keep it apart, where four would write it inside the range it breaks, no nearer itself than the
/// value it is told from, off itself by as much as it lies past its bound, or, with a fraction, whole.
pub const Number = struct {
    value: f64,
    /// The range the value breaks.
    outside: ?Range = null,
    /// A value it is told from: where a value moved onto a grid lands, or a value it does not match.
    apart: ?f64 = null,
    /// A bound it lies past: written nearer itself than the bound is.
    past: ?f64 = null,
    /// Whether the value is one with a fraction.
    fraction: bool = false,

    pub fn format(self: Number, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // A value a caller of the C API gives, or a knot's time, may be NaN or infinite.
        if (!std.math.isFinite(self.value)) return w.print("{d}", .{self.value});
        var text: [64]u8 = undefined;
        var scientific: []const u8 = undefined;
        for (3..17) |precision| {
            scientific = std.fmt.float.render(&text, self.value, .{ .precision = precision }) catch unreachable;
            const written = std.fmt.parseFloat(f64, scientific) catch unreachable;
            if (self.outside) |range| if (range.holds(written)) continue;
            if (self.apart) |other| if (@abs(written - self.value) >= @abs(written - other)) continue;
            if (self.past) |bound| if (!(@abs(written - self.value) < @abs(self.value - bound))) continue;
            if (self.fraction and written == @floor(written)) continue;
            break;
        }
        const e = std.mem.findScalar(u8, scientific, 'e').?;
        const exponent = std.fmt.parseInt(i32, scientific[e + 1 ..], 10) catch unreachable;
        if (self.value == 0 or (exponent >= -3 and exponent < 6)) return w.print("{d}", .{std.fmt.parseFloat(f64, scientific) catch unreachable});
        // The digits as written, not parsed again: rounding can carry a double past the largest.
        try w.print("{s}e{d}", .{ std.mem.trimEnd(u8, std.mem.trimEnd(u8, scientific[0..e], "0"), "."), exponent });
    }
};

pub fn parseTree(ctx: *const Ctx, given: []const u8) Error!?json.Value {
    const text = if (std.mem.startsWith(u8, given, "\xEF\xBB\xBF")) given[3..] else given;
    var scanner = json.Scanner.initCompleteInput(ctx.arena, text);
    defer scanner.deinit();
    var jd: json.Diagnostics = .{};
    scanner.enableDiagnostics(&jd);
    return json.parseFromTokenSourceLeaky(json.Value, ctx.arena, &scanner, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.diags.forSource(ctx.diags.source).err(.invalid_json, .{
                .line = std.math.lossyCast(u32, jd.getLine()),
                .column = std.math.lossyCast(u32, jd.getColumn()),
            }, "{s}", .{unparsed(e)});
            return null;
        },
    };
}

pub fn join(ctx: *const Ctx, path: []const u8, key: []const u8) Error![]const u8 {
    if (path.len == 0 and std.mem.findAny(u8, key, &control) == null) return key;
    return ctx.arena.print("{s}{s}{f}", .{ path, if (path.len == 0) "" else ".", Escaped{ .text = key } });
}

const control: [0x20]u8 = std.simd.iota(u8, 0x20);

pub fn element(ctx: *const Ctx, path: []const u8, i: usize) Error![]const u8 {
    return ctx.arena.print("{s}[{d}]", .{ path, i });
}

pub fn root(ctx: *const Ctx, value: json.Value) Node {
    return .{ .ctx = ctx, .value = value, .path = "" };
}
