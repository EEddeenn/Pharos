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

pub fn writeRun(gpa: std.mem.Allocator, io: Io, path: []const u8, run: *Run, context: anytype, comptime afterBlock: fn (@TypeOf(context), *Run, Block) void) (Io.File.OpenError || error{OutOfMemory})!Written {
    const pulled = try gpa.alloc(u8, run.info.bytes_per_epoch * pull_epochs);
    defer gpa.free(pulled);
    const buffer = try gpa.alloc(u8, buffer_bytes);
    defer gpa.free(buffer);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var writer: Io.File.Writer = .init(file, io, buffer);
    var write_failed: ?Io.File.Writer.Error = null;
    const failed: ?PullError = while (true) {
        const block = run.pull(pulled, pull_epochs) catch |e| break e;
        writer.interface.writeAll(pulled[0..block.bytes]) catch {
            write_failed = writer.err orelse error.Unexpected;
        };
        afterBlock(context, run, block);
        if (block.failed) |e| break e;
        if (block.epochs == 0 or write_failed != null) break null;
    };
    if (write_failed == null) writer.interface.flush() catch {
        write_failed = writer.err orelse error.Unexpected;
    };
    return .{ .bytes_on_file = writer.pos, .failed = failed, .write_failed = write_failed };
}
