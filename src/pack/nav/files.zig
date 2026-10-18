const std = @import("std");
const Io = std.Io;
const target = @import("shared").core.target;
const diagnostics = @import("shared").core.diagnostics;
const cli = @import("shared").cli;

pub const max_bytes: usize = 256 << 20;
const utf8_bom = "\xEF\xBB\xBF";

pub const File = struct { name: []const u8, bytes: []const u8 };

const Dir = if (target.has_file_system) struct { io: Io, base: ?[]const u8 } else noreturn;

pub const Source = union(enum) {
    dir: Dir,
    memory: []const File,
};

pub fn readResolved(arena: std.mem.Allocator, source: Source, path: []const u8, limit_bytes: usize, scope: diagnostics.Scope) diagnostics.LoadError![]const u8 {
    const text = readAt(arena, source, path, limit_bytes) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (e == error.StreamTooLong) {
            try scope.err(.io_error, null, "a file loaded by name may be at most {d} MiB", .{limit_bytes >> 20});
        } else try scope.err(.io_error, null, "cannot read the file ({f})", .{cli.FileError{ .e = e }});
        return error.IoFailed;
    };
    return if (std.mem.startsWith(u8, text, utf8_bom)) text[utf8_bom.len..] else text;
}

fn readAt(arena: std.mem.Allocator, source: Source, path: []const u8, limit_bytes: usize) ![]const u8 {
    switch (source) {
        .dir => |dir| {
            const cwd = Io.Dir.cwd();
            const limit: Io.Limit = .limited(limit_bytes + 1);
            if (!Io.Dir.path.isAbsolute(path)) {
                if (dir.base) |base| {
                    const joined = try Io.Dir.path.join(arena, &.{ base, path });
                    if (cwd.readFileAlloc(dir.io, joined, arena, limit)) |text| {
                        return text;
                    } else |err| {
                        if (err != error.FileNotFound) return err;
                    }
                }
            }
            return cwd.readFileAlloc(dir.io, path, arena, limit);
        },
        .memory => |table| {
            for (table) |file| {
                if (std.mem.eql(u8, file.name, path)) return if (file.bytes.len > limit_bytes) error.StreamTooLong else file.bytes;
            }
            return error.FileNotFound;
        },
    }
}
