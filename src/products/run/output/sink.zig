const std = @import("std");
const engine_run = @import("products/run/engine/run");

const Io = std.Io;
const Run = engine_run.Run;
const Block = engine_run.Block;
const GenerationError = engine_run.GenerationError;

const buffer_bytes: usize = 1024 * 1024;
const pull_epochs: u32 = 100;

pub const Written = struct {
    bytes_on_file: u64,
    failure: ?GenerationError,
    write_failure: ?Io.File.Writer.Error,
};

pub fn writeRun(gpa: std.mem.Allocator, io: Io, path: []const u8, run: *Run, context: anytype, comptime afterBlock: fn (@TypeOf(context), *Run, Block) void) (Io.File.OpenError || error{OutOfMemory})!Written {
    const half = run.info().bytes_per_epoch * pull_epochs;
    const pulled = try gpa.alloc(u8, 2 * half);
    defer gpa.free(pulled);
    const buffer = try gpa.alloc(u8, buffer_bytes);
    defer gpa.free(buffer);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer: Io.File.Writer = .init(file, io, buffer);
    var write_failure: ?Io.File.Writer.Error = null;
    // A block is written while the next one is pulled into the other half.
    var writing: ?Io.Future(?Io.File.Writer.Error) = null;
    var k: usize = 0;
    const failure: ?GenerationError = while (true) {
        const slot = pulled[k * half ..][0..half];
        // After a seek off the grid, the first pull stops at the grid, so every later pull is one block.
        const block = run.pull(slot, pull_epochs - @as(u32, @intCast(run.status().epoch.ms % pull_epochs))) catch unreachable;
        if (writing) |*w| write_failure = w.await(io);
        writing = if (write_failure == null) io.async(writeBlock, .{ &writer, slot[0..block.bytes] }) else null;
        afterBlock(context, run, block);
        if (block.failure) |e| break e;
        if (block.epochs == 0 or write_failure != null) break null;
        k ^= 1;
    };
    if (writing) |*w| write_failure = w.await(io);
    if (write_failure == null) writer.interface.flush() catch {
        write_failure = writer.err orelse error.Unexpected;
    };
    return .{ .bytes_on_file = writer.pos, .failure = failure, .write_failure = write_failure };
}

fn writeBlock(writer: *Io.File.Writer, bytes: []const u8) ?Io.File.Writer.Error {
    writer.interface.writeAll(bytes) catch return writer.err orelse error.Unexpected;
    return null;
}
