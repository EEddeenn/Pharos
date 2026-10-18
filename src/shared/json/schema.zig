const std = @import("std");
const Io = std.Io;
const table = @import("table.zig");
const Node = @import("node.zig").Node;

pub const About = struct { title: []const u8, description: []const u8 };

const exact_integer: f64 = 1 << 53;

pub const Schema = struct {
    jw: std.json.Stringify,

    pub fn text(self: *Schema, name: []const u8, v: []const u8) Io.Writer.Error!void {
        try self.jw.objectField(name);
        try self.jw.write(v);
    }

    fn number(self: *Schema, name: []const u8, v: f64) Io.Writer.Error!void {
        try self.jw.objectField(name);
        try self.jw.print("{d}", .{v});
    }

    pub fn words(self: *Schema, name: []const u8, list: []const []const u8) Io.Writer.Error!void {
        try self.jw.objectField(name);
        try self.jw.beginArray();
        for (list) |word| try self.jw.write(word);
        try self.jw.endArray();
    }

    pub fn begin(self: *Schema, name: []const u8) Io.Writer.Error!void {
        try self.jw.objectField(name);
        try self.jw.beginObject();
    }

    pub fn end(self: *Schema) Io.Writer.Error!void {
        try self.jw.endObject();
    }
};

pub fn write(w: *Io.Writer, comptime Root: type, comptime about: About) Io.Writer.Error!void {
    var s: Schema = .{ .jw = .{ .writer = w, .options = .{ .whitespace = .indent_2 } } };
    try s.jw.beginObject();
    try s.text("$schema", "http://json-schema.org/draft-07/schema#");
    try s.text("title", about.title);
    try s.text("description", about.description);
    try object(&s, Root);
    try s.jw.endObject();
    try w.writeByte('\n');
}

fn property(s: *Schema, comptime T: type, comptime key: table.Key) Io.Writer.Error!void {
    try s.begin(key.name);
    try s.text("description", key.doc);
    if (key.unit) |u| try s.text("x-unit", u);
    if (key.unit_key) |k| try s.text("x-unit-key", k);
    if (key.default) |d| {
        try s.jw.objectField("default");
        try defaultValue(s, d);
    }
    const Child = table.Base(T);
    if (key.one_or_many) {
        const Item = @typeInfo(Child).pointer.child;
        try s.jw.objectField("anyOf");
        try s.jw.beginArray();
        if (key.items == null or key.items.?.holds(1)) {
            try s.jw.beginObject();
            try body(s, Item, key.range);
            try s.jw.endObject();
        }
        try s.jw.beginObject();
        try s.text("type", "array");
        try s.begin("items");
        try body(s, Item, key.range);
        try s.end();
        try counts(s, key.items);
        try s.jw.endObject();
        try s.jw.endArray();
    } else {
        try body(s, Child, key.range);
        try counts(s, key.items);
    }
    try s.end();
}

fn defaultValue(s: *Schema, comptime d: table.Default) Io.Writer.Error!void {
    switch (d) {
        .number => |v| try s.jw.print("{d}", .{v}),
        .boolean => |v| try s.jw.write(v),
        .word, .text => |v| try s.jw.write(v),
        .fields => |fields| {
            try s.jw.beginObject();
            inline for (fields) |f| {
                try s.jw.objectField(f.name);
                try defaultValue(s, f.value);
            }
            try s.jw.endObject();
        },
    }
}

fn counts(s: *Schema, comptime items: ?table.Items) Io.Writer.Error!void {
    const n = items orelse return;
    try s.number("minItems", @floatFromInt(n.min));
    if (n.max) |max| try s.number("maxItems", @floatFromInt(max));
}

fn body(s: *Schema, comptime T: type, comptime range: ?table.Range) Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .float => {
            try s.text("type", "number");
            try bounds(s, range orelse .{});
        },
        .int => {
            try s.text("type", "integer");
            try bounds(s, integral(T, range orelse .{}));
        },
        .bool => try s.text("type", "boolean"),
        .@"enum" => {
            try s.text("type", "string");
            try s.words("enum", &T.words.values);
        },
        .@"struct" => if (T != Node) {
            if (@hasDecl(T, "schema")) try T.schema(s) else try object(s, T);
        },
        .pointer => |p| if (p.child == u8) try s.text("type", "string") else {
            try s.text("type", "array");
            try s.begin("items");
            try body(s, p.child, range);
            try s.end();
        },
        else => @compileError("no schema for " ++ @typeName(T)),
    }
}

fn integral(comptime T: type, comptime range: table.Range) table.Range {
    const low: f64 = @floatFromInt(std.math.minInt(T));
    const high: f64 = @floatFromInt(std.math.maxInt(T));
    const tight_min = range.min > low;
    const tight_max = range.max < high;
    return .{
        .min = if (tight_min) range.min else low,
        .open_min = tight_min and range.open_min,
        .max = if (tight_max) range.max else high,
        .open_max = tight_max and range.open_max,
    };
}

fn bounds(s: *Schema, comptime range: table.Range) Io.Writer.Error!void {
    if (std.math.isFinite(range.min) and @abs(range.min) <= exact_integer) try s.number(if (range.open_min) "exclusiveMinimum" else "minimum", range.min);
    if (std.math.isFinite(range.max) and @abs(range.max) <= exact_integer) try s.number(if (range.open_max) "exclusiveMaximum" else "maximum", range.max);
}

fn object(s: *Schema, comptime R: type) Io.Writer.Error!void {
    try s.text("type", "object");
    try s.begin("properties");
    inline for (R.table) |key| try property(s, @FieldType(R, table.fieldName(key.name)), key);
    try s.end();
    try s.jw.objectField("additionalProperties");
    try s.jw.write(false);
    const required = comptime blk: {
        var names: []const []const u8 = &.{};
        for (R.table) |key| {
            if (key.required) names = names ++ [_][]const u8{key.name};
        }
        break :blk names;
    };
    if (required.len > 0) try s.words("required", required);
    if (@hasDecl(R, "kinds")) try kinds(s, R);
    if (@hasDecl(R, "schemaMetadata")) try R.schemaMetadata(s);
}

fn kinds(s: *Schema, comptime R: type) Io.Writer.Error!void {
    const E = @TypeOf(R.kinds).Tag;
    const discriminator = comptime table.keyOf(R, R.kinds.key);
    try s.jw.objectField("oneOf");
    try s.jw.beginArray();
    inline for (comptime std.meta.tags(E)) |tag| {
        const k = comptime R.kinds.of.get(tag);
        const word = comptime E.words.get(tag);
        try s.jw.beginObject();
        try s.begin("properties");
        try s.begin(discriminator.name);
        try s.text("const", word);
        try s.end();
        inline for (k.keys) |t| try property(s, @FieldType(R, table.fieldName(t.name)), comptime table.effective(R, t));
        try s.end();
        const defaulted = comptime if (discriminator.default) |d| std.mem.eql(u8, d.word, word) else false;
        const required = comptime blk: {
            var names: []const []const u8 = if (defaulted) &.{} else &.{discriminator.name};
            for (k.keys) |t| {
                if (t.required) names = names ++ [_][]const u8{t.name};
            }
            break :blk names;
        };
        if (required.len > 0) try s.words("required", required);
        if (k.count != null or k.distinct) {
            try s.jw.objectField("oneOf");
            try s.jw.beginArray();
            inline for (comptime combinations(k)) |chosen| {
                try s.jw.beginObject();
                try s.words("required", chosen);
                try refuse(s, comptime without(k, chosen));
                try s.jw.endObject();
            }
            try s.jw.endArray();
        }
        try s.jw.endObject();
    }
    try s.jw.endArray();
}

fn refuse(s: *Schema, comptime names: []const []const u8) Io.Writer.Error!void {
    if (names.len == 0) return;
    try s.begin("not");
    try s.jw.objectField("anyOf");
    try s.jw.beginArray();
    inline for (names) |name| {
        try s.jw.beginObject();
        try s.words("required", &.{name});
        try s.jw.endObject();
    }
    try s.jw.endArray();
    try s.end();
}

fn without(comptime k: table.Kind, comptime chosen: []const []const u8) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (k.keys) |t| {
            for (chosen) |name| {
                if (std.mem.eql(u8, t.name, name)) break;
            } else names = names ++ [_][]const u8{t.name};
        }
        return names;
    }
}

fn combinations(comptime k: table.Kind) []const []const []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var out: []const []const []const u8 = &.{};
        for (0..1 << k.keys.len) |m| {
            const mask: u32 = m;
            var chosen: []const []const u8 = &.{};
            var selected: [k.keys.len]bool = undefined;
            for (k.keys, 0..) |t, i| {
                selected[i] = mask & (@as(u32, 1) << i) != 0;
                if (!selected[i]) continue;
                chosen = chosen ++ [_][]const u8{t.name};
            }
            if (k.problem(&selected) != null) continue;
            out = out ++ [_][]const []const u8{chosen};
        }
        return out;
    }
}
