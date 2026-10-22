const std = @import("std");

const Io = std.Io;

pub const Error = error{ OutOfMemory, Reported };

pub const Console = struct {
    out: *Io.Writer,
    err: *Io.Writer,

    pub fn flush(self: Console) void {
        self.out.flush() catch {};
        self.err.flush() catch {};
    }

    pub fn print(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt, args) catch {};
    }

    pub fn info(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.print("[INFO]\t" ++ fmt ++ "\n", args);
    }

    pub fn warn(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.print("[WARNING]\t" ++ fmt ++ "\n", args);
    }

    pub fn fail(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.err.print("[ERROR]\t" ++ fmt ++ "\n", args) catch {};
        self.flush();
    }
};
