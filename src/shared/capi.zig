const std = @import("std");
const builtin = @import("builtin");
const Diagnostic = @import("core.zig").diagnostics.Diagnostic;
const Diagnostics = @import("core.zig").diagnostics.Diagnostics;
const bundle = @import("bundle.zig");
const Failure = @import("stage.zig").messages.Failure;

pub const command = @import("capi/command.zig");

pub const allocator: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;

pub fn Status(comptime own: []const [:0]const u8) type {
    const names = [_][:0]const u8{ "ok", "end", "arg", "nomem", "internal" } ++ own.*;
    return @Enum(c_int, .exhaustive, &names, &std.simd.iota(c_int, names.len));
}

pub const ErrorBuffer = struct {
    buf: [256]u8 = @splat(0),
    len: usize = 0,

    pub fn begin(self: *ErrorBuffer) void {
        self.len = 0;
        self.buf[0] = 0;
    }

    pub fn set(self: *ErrorBuffer, comptime fmt: []const u8, args: anytype) void {
        const text = std.mem.print(self.buf[0..255], fmt, args) catch self.buf[0..255];
        self.len = text.len;
        self.buf[self.len] = 0;
    }

    pub fn cstr(self: *const ErrorBuffer) [*:0]const u8 {
        return self.buf[0..self.len :0];
    }
};

pub fn nomem(comptime S: type, err: *ErrorBuffer) S {
    err.set("out of memory", .{});
    return .nomem;
}

pub fn Common(comptime common: type) type {
    return struct {
        pub fn abiVersion() callconv(.c) u32 {
            return common.abi_version;
        }

        pub fn lastError() callconv(.c) [*:0]const u8 {
            return common.thread_error.cstr();
        }
    };
}

pub fn exports(comptime prefix: []const u8, comptime common: type) void {
    const symbols = Common(common);
    @export(&symbols.abiVersion, .{ .name = prefix ++ "_abi_version" });
    @export(&symbols.lastError, .{ .name = prefix ++ "_last_error" });
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

pub fn readBundle(comptime S: type, arena: std.mem.Allocator, bytes: []const u8, err: *ErrorBuffer, out: *bundle.Bundle) S {
    var diags = Diagnostics.init(arena);
    out.* = bundle.format.read(arena, bytes, diags.forSource("")) catch |e| {
        if (e == error.OutOfMemory) return nomem(S, err);
        if (diags.firstError()) |diagnostic| err.set("{f}", .{diagnostic});
        return .bundle;
    };
    return .ok;
}

pub fn failed(comptime S: type, e: Failure) S {
    return switch (e) {
        error.MessageSet => .bundle,
        error.MissingEarthOrientation, error.MissingTimeOffset, error.MissingUtcParameters => .nav,
    };
}

pub fn copyOut(comptime S: type, comptime T: type, items: []const T, buf: ?[*]T, cap: usize, len: ?*usize) S {
    if (len) |l| l.* = items.len;
    const dst = buf orelse return .arg;
    if (items.len > cap) return .arg;
    @memcpy(dst[0..items.len], items);
    return .ok;
}

pub const Diag = extern struct {
    code: u32,
    severity: u32,
    source: [*:0]const u8,
    path: [*:0]const u8,
    line: u32,
    column: u32,
    message: [*:0]const u8,
};

pub fn diagsOf(arena: std.mem.Allocator, list: []const Diagnostic) error{OutOfMemory}![]Diag {
    const out = try arena.alloc(Diag, list.len);
    for (out, list) |*c, d| c.* = .{
        .code = @backingInt(d.code),
        .severity = @backingInt(d.severity),
        .source = try arena.dupeSentinel(u8, d.source, 0),
        .path = try arena.dupeSentinel(u8, d.path, 0),
        .line = if (d.position) |position| position.line else 0,
        .column = if (d.position) |position| position.column else 0,
        .message = try arena.dupeSentinel(u8, d.message, 0),
    };
    return out;
}

pub const elided_len = 128;

pub fn elide(buffer: *[elided_len]u8, text: []const u8) []const u8 {
    if (text.len <= elided_len) return text;
    const half = (elided_len - 3) / 2;
    @memcpy(buffer[0..half], text[0..half]);
    @memcpy(buffer[half..][0..3], "...");
    @memcpy(buffer[half + 3 ..][0..half], text[text.len - half ..]);
    return buffer[0 .. 2 * half + 3];
}
