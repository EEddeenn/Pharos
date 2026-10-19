const std = @import("std");
const Io = std.Io;
const engine = @import("../engine.zig");
const Run = engine.run.Run;
const Block = engine.run.Block;
const PullError = engine.run.PullError;

const buffer_bytes: usize = 1024 * 1024;
const pull_epochs: u32 = 100;

pub const Written = struct {
    bytes_on_file: u64,
    failed: ?PullError,
    write_failed: ?Io.File.Writer.Error,
};

fn writeBlock(writer: *Io.File.Writer, bytes: []const u8) ?Io.File.Writer.Error {
    writer.interface.writeAll(bytes) catch return writer.err orelse error.Unexpected;
    return null;
}

pub fn writeRun(gpa: std.mem.Allocator, io: Io, path: []const u8, run: *Run, context: anytype, comptime afterBlock: fn (@TypeOf(context), *Run, Block) void) (Io.File.OpenError || error{OutOfMemory})!Written {
    const half = run.info.bytes_per_epoch * pull_epochs;
    const pulled = try gpa.alloc(u8, 2 * half);
    defer gpa.free(pulled);
    const buffer = try gpa.alloc(u8, buffer_bytes);
    defer gpa.free(buffer);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer: Io.File.Writer = .init(file, io, buffer);
    var write_failed: ?Io.File.Writer.Error = null;
    // A block is written while the next one is pulled into the other half.
    var writing: ?Io.Future(?Io.File.Writer.Error) = null;
    var k: usize = 0;
    const failed: ?PullError = while (true) {
        const slot = pulled[k * half ..][0..half];
        const block = run.pull(slot, pull_epochs) catch unreachable;
        if (writing) |*w| write_failed = w.await(io);
        writing = if (write_failed == null) io.async(writeBlock, .{ &writer, slot[0..block.bytes] }) else null;
        afterBlock(context, run, block);
        if (block.failed) |e| break e;
        if (block.epochs == 0 or write_failed != null) break null;
        k ^= 1;
    };
    if (writing) |*w| write_failed = w.await(io);
    if (write_failed == null) writer.interface.flush() catch {
        write_failed = writer.err orelse error.Unexpected;
    };
    return .{ .bytes_on_file = writer.pos, .failed = failed, .write_failed = write_failed };
}
