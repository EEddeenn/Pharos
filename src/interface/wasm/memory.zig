const std = @import("std");
const c_allocator = @import("interface/c/allocator");
const allocator = c_allocator.allocator;

const alignment: std.mem.Alignment = .@"16";

pub fn alloc(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    return allocator.rawAlloc(len, alignment, @returnAddress());
}

pub fn free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    allocator.rawFree(p[0..len], alignment, @returnAddress());
}
