const std = @import("std");
const build_info = @import("build_info");

pub fn Common(comptime context: type) type {
    return struct {
        pub fn abiVersion() callconv(.c) u32 {
            return context.abi_version;
        }

        pub fn sourceDigest() callconv(.c) u64 {
            return build_info.source_digest;
        }

        pub fn lastError() callconv(.c) [*:0]const u8 {
            return context.thread_error.cstr();
        }
    };
}

pub fn exportCommon(comptime context: type) void {
    const symbols = Common(context);
    @export(&symbols.abiVersion, .{ .name = context.prefix ++ "_abi_version" });
    @export(&symbols.sourceDigest, .{ .name = context.prefix ++ "_source_digest" });
    @export(&symbols.lastError, .{ .name = context.prefix ++ "_last_error" });
}

pub fn functionNames(comptime prefix: []const u8, comptime namespace: type) []const [:0]const u8 {
    comptime var out: []const [:0]const u8 = &.{};
    for (@typeInfo(namespace).@"struct".decl_names) |decl| {
        if (!std.mem.startsWith(u8, decl, prefix ++ "_")) continue;
        if (@hasDecl(namespace, "unavailable")) {
            var available = true;
            for (namespace.unavailable) |name| {
                if (std.mem.eql(u8, name, decl)) available = false;
            }
            if (!available) continue;
        }
        const T = @TypeOf(@field(namespace, decl));
        if (@typeInfo(T) != .@"fn") @compileError("an ABI declaration is not a function: " ++ decl);
        if (!std.meta.eql(@typeInfo(T).@"fn".attrs.@"callconv", std.lang.CallingConvention.c)) @compileError("an ABI function must use the C calling convention: " ++ decl);
        out = out ++ [_][:0]const u8{decl};
    }
    return out;
}

pub fn exportFunctions(comptime prefix: []const u8, comptime namespace: type) void {
    for (functionNames(prefix, namespace)) |name| @export(&@field(namespace, name), .{ .name = name });
}
