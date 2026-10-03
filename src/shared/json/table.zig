const std = @import("std");
const core = @import("../core.zig");
const dictionary = core.dictionary;
const node = @import("node.zig");
const Node = node.Node;
const Object = node.Object;
const Ctx = node.Ctx;
pub const Error = node.Error;

pub const Range = struct {
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    open_min: bool = false,
    open_max: bool = false,

    fn holds(self: Range, v: f64) bool {
        if (!std.math.isFinite(v)) return false;
        const above = if (self.open_min) v > self.min else v >= self.min;
        const below = if (self.open_max) v < self.max else v <= self.max;
        return above and below;
    }

    pub fn format(self: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{c}{d}, {d}{c}", .{ @as(u8, if (self.open_min) '(' else '['), self.min, self.max, @as(u8, if (self.open_max) ')' else ']') });
    }
};

pub const Items = struct {
    min: usize = 0,
    max: ?usize = null,

    pub fn holds(self: Items, count: usize) bool {
        return count >= self.min and (if (self.max) |max| count <= max else true);
    }

    pub fn format(self: Items, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.max) |max| {
            if (max == self.min) return w.print("exactly {d}", .{max});
            return w.print("{d} to {d}", .{ self.min, max });
        }
        try w.print("at least {d}", .{self.min});
    }
};

pub const Field = struct { name: []const u8, value: Default };

pub const Default = union(enum) {
    number: f64,
    boolean: bool,
    word: []const u8,
    text: []const u8,
    fields: []const Field,

    fn of(comptime self: Default, comptime T: type) T {
        return switch (@typeInfo(T)) {
            .float => self.number,
            .int => @intFromFloat(self.number),
            .bool => self.boolean,
            .@"enum" => dictionary.parse(T, self.word) orelse @compileError("\"" ++ self.word ++ "\" is no word of " ++ @typeName(T)),
            .pointer => self.text,
            .@"struct" => self.object(T),
            else => @compileError("no default for " ++ @typeName(T)),
        };
    }

    fn object(comptime self: Default, comptime T: type) T {
        comptime {
            for (self.fields) |f| _ = keyOf(T, f.name);
            var out: T = .{};
            for (T.table) |key| {
                const name = fieldName(key.name);
                const F = @FieldType(T, name);
                var given: ?Default = key.default;
                for (self.fields) |f| {
                    if (std.mem.eql(u8, f.name, key.name)) given = f.value;
                }
                if (given) |d| {
                    @field(out, name) = d.of(Base(F));
                } else if (@typeInfo(F) != .optional) @compileError("the default of " ++ @typeName(T) ++ " gives no " ++ key.name);
            }
            return out;
        }
    }
};

pub const Key = struct {
    name: []const u8,
    doc: []const u8,
    required: bool = false,
    range: ?Range = null,
    items: ?Items = null,
    one_or_many: bool = false,
    what: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    unit_key: ?[]const u8 = null,
    default: ?Default = null,
};

pub const Taken = struct {
    name: []const u8,
    doc: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    required: bool = false,
    range: ?Range = null,
    items: ?Items = null,
    default: ?Default = null,
    group: ?[]const u8 = null,
};

pub const Kind = struct {
    keys: []const Taken = &.{},
    count: ?u8 = null,
    distinct: bool = false,

    fn takes(comptime self: Kind, comptime name: []const u8) bool {
        for (self.keys) |t| if (std.mem.eql(u8, t.name, name)) return true;
        return false;
    }

    const Problem = union(enum) {
        count: struct { expected: u8, actual: usize },
        repeated: struct { first: usize, second: usize },
    };

    pub fn problem(self: Kind, given: []const bool) ?Problem {
        if (self.count) |want| {
            var count: usize = 0;
            for (given) |present| if (present) {
                count += 1;
            };
            if (count != want) return .{ .count = .{ .expected = want, .actual = count } };
        }
        if (self.distinct) {
            for (self.keys, 0..) |t, i| {
                if (!given[i]) continue;
                const group = t.group orelse t.name;
                for (self.keys[0..i], 0..) |other, j| {
                    if (given[j] and std.mem.eql(u8, group, other.group orelse other.name)) return .{ .repeated = .{ .first = j, .second = i } };
                }
            }
        }
        return null;
    }
};

pub fn Kinds(comptime E: type) type {
    return struct {
        key: []const u8,
        of: std.EnumArray(E, Kind),

        pub const Tag = E;
    };
}

pub fn fieldName(comptime json: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (json) |c| {
            out = out ++ (if (std.ascii.isUpper(c)) [_]u8{ '_', std.ascii.toLower(c) } else [_]u8{c});
        }
        return out;
    }
}

pub fn keyOf(comptime Raw: type, comptime name: []const u8) Key {
    for (Raw.table) |key| if (std.mem.eql(u8, key.name, name)) return key;
    @compileError(@typeName(Raw) ++ " has no key " ++ name);
}

pub fn Base(comptime F: type) type {
    return if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
}

pub fn effective(comptime Raw: type, comptime t: Taken) Key {
    comptime {
        @setEvalBranchQuota(20_000);
        const key = keyOf(Raw, t.name);
        if (key.required) @compileError(@typeName(Raw) ++ "." ++ t.name ++ " is required of every kind, so no kind may take it");
        if (key.range != null and t.range != null) @compileError(@typeName(Raw) ++ "." ++ t.name ++ " has a range, so its kinds may give none");
        if (key.default != null and t.default != null) @compileError(@typeName(Raw) ++ "." ++ t.name ++ " has a default, so its kinds may give none");
        if (key.items != null and t.items != null) @compileError(@typeName(Raw) ++ "." ++ t.name ++ " has an item count, so its kinds may give none");
        var out = key;
        out.doc = t.doc orelse key.doc;
        out.unit = t.unit orelse key.unit;
        out.required = t.required;
        out.range = t.range orelse key.range;
        out.items = t.items orelse key.items;
        out.default = t.default orelse key.default;
        return out;
    }
}

pub fn Resolved(comptime Raw: type) type {
    @setEvalBranchQuota(20_000);
    const E = @TypeOf(Raw.kinds).Tag;
    const tags = std.meta.tags(E);
    var names: [tags.len][]const u8 = undefined;
    var types: [tags.len]type = undefined;
    for (tags, &names, &types) |tag, *name, *T| {
        name.* = @tagName(tag);
        T.* = KindFields(Raw, Raw.kinds.of.get(tag));
    }
    return @Union(.auto, E, &names, &types, &@splat(.{}));
}

fn KindFields(comptime Raw: type, comptime k: Kind) type {
    @setEvalBranchQuota(20_000);
    var names: [k.keys.len][]const u8 = undefined;
    var types: [k.keys.len]type = undefined;
    for (k.keys, &names, &types) |t, *name, *T| {
        const key = effective(Raw, t);
        name.* = fieldName(t.name);
        const V = Base(@FieldType(Raw, name.*));
        T.* = if (key.required or key.default != null) V else ?V;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub fn read(comptime Raw: type, obj: Object) Error!?Raw {
    var raw: Raw = .{};
    var ok = true;
    inline for (Raw.table) |key| {
        const name = comptime fieldName(key.name);
        const F = @FieldType(Raw, name);
        const optional = @typeInfo(F) == .optional;
        if (optional == (key.required or key.default != null)) @compileError(@typeName(Raw) ++ "." ++ name ++ " must be optional exactly when its key is neither required nor defaulted");
        if (try obj.get(key.name)) |n| {
            if (try value(Base(F), n, key)) |v| @field(raw, name) = v else ok = false;
        } else if (key.required) {
            try missing(obj.node.ctx, try obj.childPath(key.name));
            ok = false;
        } else if (key.default) |d| {
            @field(raw, name) = comptime d.of(Base(F));
        }
    }
    if (@hasDecl(Raw, "kinds") and ok) try unused(Raw, raw, obj);
    try obj.finish();
    return if (ok) raw else null;
}

fn unused(comptime Raw: type, raw: Raw, obj: Object) Error!void {
    const E = @TypeOf(Raw.kinds).Tag;
    const discriminator = comptime keyOf(Raw, Raw.kinds.key);
    switch (@field(raw, fieldName(Raw.kinds.key))) {
        inline else => |tag| {
            const k = comptime Raw.kinds.of.get(tag);
            inline for (Raw.table) |key| {
                if (comptime !k.takes(key.name) and elsewhere(Raw, key.name)) {
                    if (obj.map.getIndex(key.name) != null) try obj.node.ctx.diags.warn(.no_effect, try obj.childPath(key.name), "the {s} {s} takes no {s}", .{ E.words.get(tag), discriminator.what orelse discriminator.name, key.what orelse key.name });
                }
            }
        },
    }
}

fn elsewhere(comptime Raw: type, comptime name: []const u8) bool {
    for (Raw.kinds.of.values) |k| if (k.takes(name)) return true;
    return false;
}

pub fn defaults(comptime Raw: type) Raw {
    comptime {
        var raw: Raw = .{};
        for (Raw.table) |key| {
            if (key.required) @compileError(@typeName(Raw) ++ " has a required key, so no defaults");
            if (key.default) |d| @field(raw, fieldName(key.name)) = d.of(Base(@FieldType(Raw, fieldName(key.name))));
        }
        return raw;
    }
}

fn missing(ctx: *const Ctx, path: []const u8) Error!void {
    try ctx.diags.err(.missing_field, path, "required", .{});
}

fn outside(ctx: *const Ctx, path: []const u8, range: Range, v: f64) Error!void {
    try ctx.diags.err(.out_of_range, path, "must be in {f}, got {d}", .{ range, v });
}

fn value(comptime T: type, n: Node, comptime key: Key) Error!?T {
    switch (@typeInfo(T)) {
        .float => {
            const v = try n.number() orelse return null;
            return if (try inRange(n, key.range, v)) v else null;
        },
        .int => {
            const v = try n.integer(T) orelse return null;
            return if (try inRange(n, key.range, @floatFromInt(v))) v else null;
        },
        .bool => return n.boolean(),
        .@"enum" => return n.word(T, key.what orelse key.name),
        .@"struct" => {
            if (T == Node) return n;
            if (@hasDecl(T, "fromJson")) return T.fromJson(n);
            const obj = try n.object() orelse return null;
            return read(T, obj);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("no JSON reading for " ++ @typeName(T));
            if (p.child == u8) return n.string();
            return slice(p.child, n, key);
        },
        else => @compileError("no JSON reading for " ++ @typeName(T)),
    }
}

fn slice(comptime E: type, n: Node, comptime key: Key) Error!?[]const E {
    const arena = n.ctx.arena;
    const element_key = comptime blk: {
        var item = key;
        item.items = null;
        item.one_or_many = false;
        break :blk item;
    };
    if (key.one_or_many and n.value != .array) {
        const ok = try itemCount(n.ctx, n.path, key.items, 1);
        const one = try value(E, n, element_key) orelse return null;
        if (!ok) return null;
        const out = try arena.alloc(E, 1);
        out[0] = one;
        return out;
    }
    const items = try n.array() orelse return null;
    const out = try arena.alloc(E, items.len);
    var ok = try itemCount(n.ctx, n.path, key.items, items.len);
    for (items, 0..) |item, i| {
        out[i] = try value(E, try n.item(i, item), element_key) orelse {
            ok = false;
            continue;
        };
    }
    return if (ok) out else null;
}

fn itemCount(ctx: *const Ctx, path: []const u8, comptime items: ?Items, count: usize) Error!bool {
    const bounds = items orelse return true;
    if (bounds.holds(count)) return true;
    const singular = bounds.min == 1 and (bounds.max == null or bounds.max.? == 1);
    try ctx.diags.err(.out_of_range, path, "must contain {f} item{s}, got {d}", .{ bounds, if (singular) "" else "s", count });
    return false;
}

fn inRange(n: Node, comptime range: ?Range, v: f64) Error!bool {
    const r = range orelse return true;
    if (r.holds(v)) return true;
    try outside(n.ctx, n.path, r, v);
    return false;
}

pub fn kind(comptime Raw: type, raw: Raw, ctx: *const Ctx, path: []const u8) Error!?Resolved(Raw) {
    switch (@field(raw, fieldName(Raw.kinds.key))) {
        inline else => |tag| {
            const k = comptime Raw.kinds.of.get(tag);
            var out: @FieldType(Resolved(Raw), @tagName(tag)) = undefined;
            var ok = true;
            var selected: [k.keys.len]bool = undefined;
            inline for (k.keys, 0..) |t, i| {
                const key = comptime effective(Raw, t);
                const name = comptime fieldName(t.name);
                const given: ?Base(@FieldType(Raw, name)) = @field(raw, name);
                selected[i] = given != null;
                if (given) |v| {
                    if (t.range) |range| {
                        const x: f64 = if (@typeInfo(@TypeOf(v)) == .int) @floatFromInt(v) else v;
                        if (ok and !range.holds(x)) {
                            try outside(ctx, try node.join(ctx, path, t.name), range, x);
                            ok = false;
                        }
                    }
                    if (t.items) |items| if (!try itemCount(ctx, try node.join(ctx, path, t.name), items, v.len)) {
                        ok = false;
                    };
                    @field(out, name) = v;
                } else if (key.required) {
                    try missing(ctx, try node.join(ctx, path, t.name));
                    ok = false;
                } else if (key.default) |d| {
                    @field(out, name) = comptime d.of(Base(@FieldType(Raw, name)));
                } else @field(out, name) = null;
            }
            if (k.problem(&selected)) |problem| {
                const E = @TypeOf(Raw.kinds).Tag;
                const discriminator = comptime keyOf(Raw, Raw.kinds.key);
                const word = E.words.get(tag);
                const what = discriminator.what orelse discriminator.name;
                switch (problem) {
                    .count => |count| try ctx.diags.err(
                        .out_of_range,
                        path,
                        "the {s} {s} takes {d} of {f}; {d} given ({f})",
                        .{ word, what, count.expected, KeyList{ .keys = k.keys }, count.actual, KeyList{ .keys = k.keys, .selected = &selected } },
                    ),
                    .repeated => |pair| if (comptime k.distinct) {
                        const first = k.keys[pair.first];
                        const second = k.keys[pair.second];
                        try ctx.diags.err(
                            .out_of_range,
                            path,
                            "the {s} {s} takes keys from distinct groups; {s} and {s} both belong to {s}",
                            .{ word, what, first.name, second.name, first.group orelse first.name },
                        );
                    },
                }
                ok = false;
            }
            return if (ok) @unionInit(Resolved(Raw), @tagName(tag), out) else null;
        },
    }
}

const KeyList = struct {
    keys: []const Taken,
    selected: ?[]const bool = null,

    pub fn format(self: KeyList, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        for (self.keys, 0..) |key, i| {
            if (self.selected) |selected| if (!selected[i]) continue;
            if (!first) try w.writeAll(", ");
            try w.writeAll(key.name);
            first = false;
        }
        if (first) try w.writeAll("none");
    }
};
