const std = @import("std");
const allocator = @import("shared").capi.allocator;
const options = @import("wasm_options");
const product = @field(@import("abi.zig"), options.product);
const layout = @import("wasm/layout.zig").text(product);

export fn pharos_wasm_layout() [*:0]const u8 {
    return layout.ptr;
}

comptime {
    _ = product.common;
    for (product.modules) |module| _ = module;
}

const alignment: std.mem.Alignment = .@"16";

export fn pharos_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    return allocator.rawAlloc(len, alignment, @returnAddress());
}

export fn pharos_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    allocator.rawFree(p[0..len], alignment, @returnAddress());
}
