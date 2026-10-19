const std = @import("std");
const Io = std.Io;
const json = @import("shared").json;
const trajectory = @import("pharos_traj").plan.read;
const scenario = @import("pharos_pack").scenario.read;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedTwoPaths;
    try emit(init.io, args[1], trajectory.Raw, .{
        .title = "Pharos trajectory plan",
        .description = "The trajectory plan that pharos-traj build and pharos_traj_build read: a start, and the segments that follow it, each built from the state the one before leaves. The plan reader alone validates; the build then holds the path against the receiver's domain and against its limits.",
    });
    try emit(init.io, args[2], scenario.Raw, .{
        .title = "Pharos scenario",
        .description = "The scenario that pharos-pack and pharos_pack_create read. It names every key the reader takes, with its default, unit and kind rules, for forms and hints; the reader alone validates.",
    });
}

fn emit(io: Io, path: []const u8, comptime Root: type, comptime about: json.schema.About) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = Io.File.Writer.init(file, io, &buffer);
    json.schema.write(&writer.interface, Root, about) catch return writer.err orelse error.WriteFailed;
    writer.interface.flush() catch return writer.err orelse error.WriteFailed;
}
