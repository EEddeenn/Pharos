const std = @import("std");

const Io = std.Io;

/// A system file error rendered as a short sentence.
pub const FileError = struct {
    e: anyerror,

    pub fn format(self: FileError, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(switch (self.e) {
            error.IsDir => "it is a directory",
            error.NotDir => "a part of the path is not a directory",
            error.SymLinkLoop => "too many symbolic links",
            error.InputOutput => "an input or output error",
            error.Unexpected => "an unexpected error of the system",
            error.SystemResources => "the system is short of resources",
            error.WouldBlock => "it would have to wait",
            error.Streaming => "it is a stream, not a file",
            error.ProcessFdQuotaExceeded => "too many files are open in this process",
            error.SystemFdQuotaExceeded => "too many files are open in the system",
            error.DiskQuota => "the disk quota is used up",
            error.SocketUnconnected => "the socket is not connected",
            error.NoDevice => "no such device",
            error.LockViolation => "another process has locked it",
            error.FileLocksUnsupported => "the file system has no file locks",
            error.LinkQuotaExceeded => "too many links",
            error.ReadOnlyFileSystem => "the file system is read-only",
            else => {
                for (@errorName(self.e), 0..) |c, i| {
                    if (i > 0 and std.ascii.isUpper(c)) try w.writeByte(' ');
                    try w.writeByte(std.ascii.toLower(c));
                }
                return;
            },
        });
    }
};
