const std = @import("std");
const bitwriter = @import("bitwriter.zig");
const scaling = @import("scaling.zig");

const Repr = scaling.Repr;
const eval_quota = 100_000;

pub const Error = scaling.Error;

pub const NoSource = struct {};
pub const no_source: NoSource = .{};

pub fn Field(comptime Source: type) type {
    return struct {
        const Row = @This();
        pub const Part = struct { of: *const Row, shift: u7 };
        const Src = union(enum) {
            field: [:0]const u8,
            computed: *const fn (*const Source) f64,
            computed_opt: *const fn (*const Source) ?f64,
            computed_int: *const fn (*const Source) i64,
            part: Part,
            ctx: [:0]const u8,
            constant: u64,
            reserved,
            parity_fill,
        };

        name: [:0]const u8,
        width: u7,
        repr: Repr = .unsigned,
        scale_log2: i8 = 0,
        semicircles: bool = false,
        periodic: bool = false,
        renamed: bool = false,
        src: Src,
    };
}

pub fn reservedRows(comptime Source: type, comptime name: [:0]const u8, comptime width: usize) [(width + 63) / 64]Field(Source) {
    var rows: [(width + 63) / 64]Field(Source) = undefined;
    var left = width;
    for (&rows, 0..) |*row, k| {
        const w = @min(left, 64);
        row.* = .{ .name = if (k == 0) name else std.fmt.comptimePrint("{s}_{d}", .{ name, k + 1 }), .width = @intCast(w), .src = .reserved };
        left -= w;
    }
    return rows;
}

pub fn encode(comptime Source: type, comptime layout: []const Field(Source), src: *const Source, ctx: anytype, w: *bitwriter.BitWriter) Error!void {
    @setEvalBranchQuota(eval_quota);
    comptime lint(Source, layout);
    inline for (layout) |row| {
        const raw: @Int(.unsigned, row.width) = switch (row.src) {
            .field, .computed, .computed_opt, .computed_int, .part => try fromSource(Source, row, src),
            .ctx => |name| try scaling.fromInt(row.width, row.repr, asInt(@field(ctx, name))),
            .constant => |c| c,
            .reserved, .parity_fill => 0,
        };
        w.writeBits(row.width, raw);
    }
}

pub fn fits(comptime Source: type, comptime layout: []const Field(Source), src: *const Source) bool {
    return misfit(Source, layout, src) == null;
}

pub fn misfit(comptime Source: type, comptime layout: []const Field(Source), src: *const Source) ?[:0]const u8 {
    @setEvalBranchQuota(eval_quota);
    comptime lint(Source, layout);
    inline for (layout) |row| switch (row.src) {
        .field, .computed, .computed_opt, .computed_int, .part => _ = fromSource(Source, row, src) catch return row.name,
        .ctx, .constant, .reserved, .parity_fill => {},
    };
    return null;
}

pub fn totalWidth(comptime Source: type, comptime layout: []const Field(Source)) comptime_int {
    @setEvalBranchQuota(eval_quota);
    comptime var total = 0;
    inline for (layout) |row| total += row.width;
    return total;
}

pub fn rowOf(comptime Source: type, comptime layout: []const Field(Source), comptime name: []const u8) Field(Source) {
    @setEvalBranchQuota(eval_quota);
    inline for (layout) |row| if (std.mem.eql(u8, row.name, name)) return row;
    @compileError("no row named " ++ name);
}

pub fn Decoded(comptime Source: type, comptime layout: []const Field(Source)) type {
    @setEvalBranchQuota(eval_quota);
    comptime lint(Source, layout);
    comptime var names: [layout.len][:0]const u8 = undefined;
    comptime var types: [layout.len]type = undefined;
    comptime var attrs: [layout.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (layout, 0..) |row, i| {
        names[i] = row.name;
        types[i] = RowType(Source, row);
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn RowType(comptime Source: type, comptime row: Field(Source)) type {
    return @Int(if (row.repr == .twos) .signed else .unsigned, row.width);
}

pub fn decode(comptime Source: type, comptime layout: []const Field(Source), words: *const [(totalWidth(Source, layout) + 31) / 32]u32) Decoded(Source, layout) {
    @setEvalBranchQuota(eval_quota);
    var r: bitwriter.BitReader = .{ .words = words };
    var out: Decoded(Source, layout) = undefined;
    inline for (layout) |row| @field(out, row.name) = r.readBits(RowType(Source, row));
    return out;
}

pub fn value(comptime Source: type, comptime layout: []const Field(Source), comptime name: []const u8, decoded: Decoded(Source, layout)) f64 {
    const row = comptime rowOf(Source, layout, name);
    const v = scaling.dequantize(row.width, row.repr, row.scale_log2, @bitCast(@field(decoded, name)));
    return if (row.semicircles) v * std.math.pi else v;
}

fn fromSource(comptime Source: type, comptime row: Field(Source), src: *const Source) scaling.Error!@Int(.unsigned, row.width) {
    return switch (row.src) {
        .field => |path| fromLeaf(Source, row, resolve(Source, src, path).*),
        .computed => |f| quantizeRow(Source, row, f(src)),
        .computed_opt => |f| quantizeRow(Source, row, f(src) orelse return error.ValueMissing),
        .computed_int => |f| scaling.fromInt(row.width, row.repr, f(src)),
        .part => |p| @truncate(try fromSource(Source, p.of.*, src) >> p.shift),
        else => @compileError("row " ++ row.name ++ " does not read the record"),
    };
}

fn quantizeRow(comptime Source: type, comptime row: Field(Source), v: f64) error{FieldOverflow}!@Int(.unsigned, row.width) {
    const x = if (row.semicircles) v / std.math.pi else v;
    if (row.periodic) return scaling.quantizeAngle(row.width, row.repr, x);
    return scaling.quantize(row.width, row.repr, row.scale_log2, x);
}

fn fromLeaf(comptime Source: type, comptime row: Field(Source), leaf: anytype) error{FieldOverflow}!@Int(.unsigned, row.width) {
    return switch (@typeInfo(@TypeOf(leaf))) {
        .float => quantizeRow(Source, row, leaf),
        .int, .bool => scaling.fromInt(row.width, row.repr, asInt(leaf)),
        else => @compileError("row " ++ row.name ++ ": unsupported leaf type " ++ @typeName(@TypeOf(leaf))),
    };
}

fn asInt(v: anytype) i128 {
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => @intFromBool(v),
        .int, .comptime_int => v,
        else => @compileError("expected an integer or bool, found " ++ @typeName(@TypeOf(v))),
    };
}

fn resolve(comptime Source: type, src: *const Source, comptime path: []const u8) *const LeafType(Source, path) {
    if (comptime std.mem.findScalar(u8, path, '.')) |dot| {
        const component = path[0..dot];
        return resolve(@FieldType(Source, component), &@field(src.*, component), path[dot + 1 ..]);
    }
    return &@field(src.*, path);
}

fn LeafType(comptime Source: type, comptime path: []const u8) type {
    @setEvalBranchQuota(eval_quota);
    comptime var it = std.mem.splitScalar(u8, path, '.');
    comptime var T: type = Source;
    inline while (comptime it.next()) |component| T = @FieldType(T, component);
    return T;
}

fn lint(comptime Source: type, comptime layout: []const Field(Source)) void {
    comptime {
        @setEvalBranchQuota(eval_quota);
        for (layout, 0..) |row, i| {
            if (row.width < 1 or row.width > 64) @compileError("row " ++ row.name ++ ": width must be 1..64");
            if (row.periodic) {
                const float = switch (row.src) {
                    .computed, .computed_opt => true,
                    .field => |path| @typeInfo(LeafType(Source, path)) == .float,
                    else => false,
                };
                if (!(float and row.semicircles and row.repr != .unsigned and row.scale_log2 == 1 - @as(i32, row.width))) {
                    @compileError("row " ++ row.name ++ ": a periodic row is a float in a signed semicircle field spanning the circle");
                }
            }
            for (layout[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.name, row.name)) @compileError("duplicate row name " ++ row.name);
            }
            switch (row.src) {
                .field => |path| {
                    const last = if (std.mem.findScalarLast(u8, path, '.')) |dot| path[dot + 1 ..] else path;
                    if (!row.renamed and !std.mem.eql(u8, last, row.name)) {
                        @compileError("row " ++ row.name ++ " reads " ++ path ++ "; mark it .renamed if intended");
                    }
                    _ = LeafType(Source, path);
                },
                .constant => |c| if (c > scaling.mask(row.width)) @compileError("row " ++ row.name ++ ": constant does not fit"),
                .part => |p| {
                    lint(Source, &.{p.of.*});
                    if (row.repr != .unsigned or p.shift + row.width > p.of.width) @compileError("row " ++ row.name ++ ": a part row holds unsigned bits of its whole");
                },
                .computed, .computed_opt, .computed_int, .ctx, .reserved, .parity_fill => {},
            }
        }
    }
}
