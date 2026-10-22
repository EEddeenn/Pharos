const std = @import("std");
const builtin = @import("builtin");

pub const allocator: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm()) wasm_allocator else std.heap.smp_allocator;

/// Zig's WebAssembly allocator, with no block resized where it lies: its `resize` keeps a block of one 64 KiB page in
/// place when it is cut below 32 KiB, and its `free` then files the block as one of 32 KiB, so that every call that
/// cuts such a block takes 64 KiB more of the memory (Zig 0.17).
const wasm_allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = std.heap.WasmAllocator.vtable.alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.heap.WasmAllocator.vtable.free,
} };
