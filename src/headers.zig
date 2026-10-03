const std = @import("std");
const Io = std.Io;
const abi = @import("abi.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != abi.products.len + 1) return error.ExpectedHeaderPaths;
    inline for (abi.products, 1..) |product, i| {
        const file = try Io.Dir.cwd().createFile(init.io, args[i], .{});
        defer file.close(init.io);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = Io.File.Writer.init(file, init.io, &buffer);
        write(&writer.interface, product) catch return writer.err orelse error.WriteFailed;
        writer.interface.flush() catch return writer.err orelse error.WriteFailed;
    }
}

fn write(w: *Io.Writer, comptime product: abi.Product) Io.Writer.Error!void {
    @setEvalBranchQuota(100_000);
    const upper = comptime abi.upper(product.prefix);
    try w.print("#ifndef {s}_H\n#define {s}_H\n\n#include <stddef.h>\n#include <stdint.h>\n\n#ifdef __cplusplus\nextern \"C\" {{\n#endif\n\n#define {s}_ABI_VERSION 0x{x:0>8}u\n\n", .{ upper, upper, upper, product.common.abi_version });

    try enumeration(w, .{ .type = product.common.Status, .name = product.prefix ++ "_status", .prefix = upper }, true);
    inline for (product.enums) |e| try enumeration(w, e, false);

    inline for (product.handles) |h| try w.print("typedef struct {s} {s};\n", .{ h.name, h.name });
    inline for (product.records) |record| try w.print("typedef struct {s} {s};\n", .{ record.name, record.name });
    try w.writeAll("\n");
    inline for (product.records) |record| {
        const info = @typeInfo(record.type).@"struct";
        if (info.layout != .@"extern") @compileError("an ABI record must be extern: " ++ record.name);
        try w.print("struct {s} {{\n", .{record.name});
        inline for (info.fields) |field| {
            switch (@typeInfo(field.type)) {
                .array => |a| try w.print("    {s} {s}[{d}];\n", .{ comptime cName(product, a.child), field.name, a.len }),
                else => try w.print("    {s} {s};\n", .{ comptime cName(product, field.type), field.name }),
            }
        }
        try w.writeAll("};\n\n");
    }

    inline for (comptime abi.functions(product)) |function| {
        const info = @typeInfo(function.type).@"fn";
        if (info.is_var_args or info.is_generic) @compileError("an ABI function must have fixed typed arguments: " ++ function.name);
        try w.print("{s} {s}(", .{ comptime cName(product, info.return_type.?), function.name });
        if (info.params.len == 0) try w.writeAll("void");
        inline for (info.params, 0..) |param, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(comptime cName(product, param.type.?));
        }
        try w.writeAll(");\n");
    }
    try w.writeAll("\n#ifdef __cplusplus\n}\n#endif\n\n#endif\n");
}

fn enumeration(w: *Io.Writer, comptime e: abi.Enum, comptime status: bool) Io.Writer.Error!void {
    const info = @typeInfo(e.type).@"enum";
    const Storage = if (@bitSizeOf(info.tag_type) == @sizeOf(e.type) * 8) info.tag_type else std.meta.Int(@typeInfo(info.tag_type).int.signedness, @sizeOf(e.type) * 8);
    try w.print("typedef {s} {s};\nenum {{\n", .{ comptime integer(Storage), e.name });
    inline for (info.fields, 0..) |field, i| {
        const failure = status and !std.mem.eql(u8, field.name, "ok") and !std.mem.eql(u8, field.name, "end");
        try w.print("    {s}_{s}{s} = {d}{s}\n", .{ e.prefix, if (failure) "E_" else "", comptime abi.upper(field.name), field.value, if (i + 1 == info.fields.len) "" else "," });
    }
    try w.writeAll("};\n\n");
}

fn integer(comptime T: type) []const u8 {
    if (T == usize) return "size_t";
    if (T == isize) return "ptrdiff_t";
    if (T == c_int) return "int";
    if (T == c_uint) return "unsigned int";
    const info = @typeInfo(T).int;
    return switch (info.bits) {
        8, 16, 32, 64 => std.fmt.comptimePrint("{s}int{d}_t", .{ if (info.signedness == .unsigned) "u" else "", info.bits }),
        else => @compileError("no C ABI integer for " ++ @typeName(T)),
    };
}

fn cName(comptime product: abi.Product, comptime T: type) []const u8 {
    if (T == product.common.Status) return product.prefix ++ "_status";
    for (product.handles) |h| if (T == h.type) return h.name;
    for (product.records) |r| if (T == r.type) return r.name;
    for (product.enums) |e| if (T == e.type) return e.name;
    return switch (@typeInfo(T)) {
        .void => "void",
        .int => integer(T),
        .float => |f| switch (f.bits) {
            32 => "float",
            64 => "double",
            else => @compileError("no C ABI float for " ++ @typeName(T)),
        },
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => cName(product, o.child),
            else => @compileError("only pointer optionals belong in the C ABI: " ++ @typeName(T)),
        },
        .pointer => |p| blk: {
            if (p.size == .slice) @compileError("slices do not belong in the C ABI: " ++ @typeName(T));
            const child = if (p.child == u8 and p.sentinel_ptr != null) "char" else cName(product, p.child);
            break :blk child ++ (if (p.is_const) " const" else "") ++ " *";
        },
        else => @compileError("unnamed C ABI type: " ++ @typeName(T)),
    };
}
