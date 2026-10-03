const std = @import("std");
const abi = @import("../abi.zig");

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
    out = out ++ enumeration(product.prefix ++ "_status", product.common.Status);
    for (product.enums) |e| out = out ++ "," ++ enumeration(e.name, e.type);
    return out ++ "}}\x00";
}

fn recordLayout(comptime record: abi.Named) []const u8 {
    comptime var out: []const u8 = std.fmt.comptimePrint(
        "\"{s}\":{{\"size\":{d},\"align\":{d},\"fields\":{{",
        .{ record.name, @sizeOf(record.type), @alignOf(record.type) },
    );
    for (@typeInfo(record.type).@"struct".fields, 0..) |field, i| {
        if (i > 0) out = out ++ ",";
        out = out ++ std.fmt.comptimePrint(
            "\"{s}\":{{\"offset\":{d},\"size\":{d}",
            .{ field.name, @offsetOf(record.type, field.name), @sizeOf(field.type) },
        );
        if (@typeInfo(field.type) == .array) {
            out = out ++ std.fmt.comptimePrint(
                ",\"elementSize\":{d}",
                .{@sizeOf(@typeInfo(field.type).array.child)},
            );
        }
        out = out ++ "}";
    }
    return out ++ "}}";
}

fn enumeration(comptime name: []const u8, comptime T: type) []const u8 {
    comptime var out: []const u8 = "\"" ++ name ++ "\":{";
    for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
        out = out ++ (if (i > 0) "," else "") ++ "\"" ++ field.name ++ "\":" ++ std.fmt.comptimePrint("{d}", .{field.value});
    }
    return out ++ "}";
}
