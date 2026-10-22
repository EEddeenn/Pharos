const std = @import("std");
const cli_console = @import("interface/cli/console");
const diagnostics = @import("base/diagnostics");

const Io = std.Io;
const Console = cli_console.Console;
const CliError = cli_console.Error;
const Escaped = diagnostics.Escaped;
const Number = @import("base/text/number").Number;
const FileError = @import("base/text/file_error").FileError;

pub const max_input_bytes: usize = 1 << 30;

/// Owns the open file. After open, the writer borrows this object's buffer, so the object must not move.
pub const FileWriter = struct {
    file: Io.File,
    writer: Io.File.Writer,
    buffer: [64 * 1024]u8,

    pub fn open(self: *FileWriter, io: Io, path: []const u8) Io.File.OpenError!void {
        self.file = try Io.Dir.cwd().createFile(io, path, .{});
        self.writer = Io.File.Writer.init(self.file, io, &self.buffer);
    }

    pub fn close(self: *FileWriter, io: Io) void {
        self.file.close(io);
    }

    pub fn interface(self: *FileWriter) *Io.Writer {
        return &self.writer.interface;
    }

    pub fn flush(self: *FileWriter) (Io.File.Writer.Error || Io.Writer.Error)!void {
        self.writer.interface.flush() catch |e| return self.writer.err orelse e;
        if (self.writer.err) |e| return e;
    }
};

pub fn readFile(io: Io, arena: std.mem.Allocator, path: []const u8, max_bytes: usize, console: Console) CliError![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes + 1)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        const quoted: Escaped = .{ .text = path };
        if (e == error.StreamTooLong) {
            const cap = max_bytes >> 20;
            if (Io.Dir.cwd().statFile(io, path, .{})) |st| {
                const size: Number = .{ .value = mib(st.size), .outside = .{ .max = @floatFromInt(cap) } };
                console.fail("Cannot read {f}: the file is {f} MiB; this input may be at most {d} MiB", .{ quoted, size, cap });
            } else |_| console.fail("Cannot read {f}: this input may be at most {d} MiB", .{ quoted, cap });
        } else console.fail("Cannot read {f}: {f}", .{ quoted, FileError{ .e = e } });
        return error.Reported;
    };
}

pub fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

pub fn cannotWrite(console: Console, path: []const u8, e: anyerror) void {
    console.fail("Cannot write {f}: {f}", .{ Escaped{ .text = path }, FileError{ .e = e } });
}

pub fn writeFile(io: Io, path: []const u8, bytes: []const u8, console: Console) CliError!void {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |e| {
        cannotWrite(console, path, e);
        return error.Reported;
    };
}

pub fn withExtension(arena: std.mem.Allocator, path: []const u8, extension: []const u8) error{OutOfMemory}![]const u8 {
    const ext = std.Io.Dir.path.extension(path);
    return arena.print("{s}.{s}", .{ path[0 .. path.len - ext.len], extension });
}
