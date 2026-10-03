const std = @import("std");
const core = @import("../core.zig");
const dictionary = core.dictionary;
const json = std.json;
const Diagnostics = core.diagnostics.Diagnostics;

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
        try self.ctx.diags.err(.wrong_type, self.path, "expected {s}, found {s}", .{ expected, @tagName(self.value) });
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

    pub fn integer(self: Node, comptime T: type) Error!?T {
        const v: i64 = switch (self.value) {
            .integer => |i| i,
            .float => |f| blk: {
                if (f != @floor(f) or !std.math.isFinite(f)) {
                    try self.wrongType("an integer");
                    return null;
                }
                if (f < -max_integer_f64 or f > max_integer_f64) {
                    try self.ctx.diags.err(.out_of_range, self.path, "{d} does not fit an integer", .{f});
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
        return std.math.cast(T, v) orelse {
            try self.ctx.diags.err(.out_of_range, self.path, "{d} is out of range", .{v});
            return null;
        };
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
            try self.ctx.diags.err(.unknown_name, self.path, "unknown {s} \"{s}\"; the {s} words are {s}", .{ what, text, what, comptime dictionary.words(E) });
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

    pub fn finish(self: Object) Error!void {
        for (self.map.keys(), self.seen) |key, was_seen| {
            if (!was_seen) try self.node.ctx.diags.warn(.unknown_key, try self.childPath(key), "unknown key, ignored", .{});
        }
    }
};

pub fn parseTree(ctx: *const Ctx, text: []const u8) Error!?json.Value {
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
            }, "{s}", .{@errorName(e)});
            return null;
        },
    };
}

pub fn join(ctx: *const Ctx, path: []const u8, key: []const u8) Error![]const u8 {
    if (path.len == 0) return key;
    return std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
}

pub fn element(ctx: *const Ctx, path: []const u8, i: usize) Error![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s}[{d}]", .{ path, i });
}

pub fn root(ctx: *const Ctx, value: json.Value) Node {
    return .{ .ctx = ctx, .value = value, .path = "" };
}
