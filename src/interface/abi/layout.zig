const std = @import("std");
const abi = @import("interface/abi/catalog");

pub fn text(comptime product: abi.Product) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    comptime var out: []const u8 = std.fmt.comptimePrint(
        "{{\"pointerSize\":{d},\"sizeSize\":{d},\"types\":{{",
        .{ @sizeOf(*u8), @sizeOf(usize) },
    );
    for (product.records, 0..) |record, i| {
        if (i > 0) out = out ++ ",";
        out = out ++ recordLayout(record);
    }

    out = out ++ "},\"enums\":{";
    out = out ++ enumeration(product.context.prefix ++ "_status", product.context.Status);
    for (product.enums) |e| out = out ++ "," ++ enumeration(e.name, e.type);
    return out ++ "}}\x00";
}

fn recordLayout(comptime record: abi.Named) []const u8 {
    comptime var out: []const u8 = std.fmt.comptimePrint(
        "\"{s}\":{{\"size\":{d},\"align\":{d},\"fields\":{{",
        .{ record.name, @sizeOf(record.type), @alignOf(record.type) },
    );
    const info = @typeInfo(record.type).@"struct";
    for (info.field_names, info.field_types, 0..) |name, Field, i| {
        if (i > 0) out = out ++ ",";
        out = out ++ std.fmt.comptimePrint(
            "\"{s}\":{{\"offset\":{d},\"size\":{d}",
            .{ name, @offsetOf(record.type, name), @sizeOf(Field) },
        );
        if (@typeInfo(Field) == .array) {
            out = out ++ std.fmt.comptimePrint(
                ",\"elementSize\":{d}",
                .{@sizeOf(@typeInfo(Field).array.child)},
            );
        }
        out = out ++ "}";
    }
    return out ++ "}}";
}

fn enumeration(comptime name: []const u8, comptime T: type) []const u8 {
    comptime var out: []const u8 = "\"" ++ name ++ "\":{";
    const info = @typeInfo(T).@"enum";
    for (info.field_names, info.field_values, 0..) |tag, value, i| {
        out = out ++ (if (i > 0) "," else "") ++ "\"" ++ tag ++ "\":" ++ std.fmt.comptimePrint("{d}", .{value});
    }
    return out ++ "}";
}
