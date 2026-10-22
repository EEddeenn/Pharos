const std = @import("std");
const json_schema = @import("base/json/schema");
const trajectory = @import("products/traj/input/read");
const scenario = @import("products/pack/input/scenario/schema");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputDirectory;
    const directory = try Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer directory.close(init.io);
    try emit(init.io, directory, "trajectory.schema.json", trajectory.Raw, .{
        .title = "Pharos trajectory plan",
        .description = "The trajectory plan that pharos-traj build and pharos_traj_build read: a start, and the segments that follow it, each built from the state the one before leaves. The plan reader alone validates; the build then holds the path against the receiver's domain and against its limits.",
    });
    try emit(init.io, directory, "scenario.schema.json", scenario.Raw, .{
        .title = "Pharos scenario",
        .description = "The scenario that pharos-pack and pharos_pack_create read. It names every key the reader takes, with its default, unit and kind rules, for forms and hints; the reader alone validates.",
    });
}

fn emit(io: Io, directory: Io.Dir, name: []const u8, comptime Root: type, comptime about: json_schema.About) !void {
    const file = try directory.createFile(io, name, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = Io.File.Writer.init(file, io, &buffer);
    json_schema.write(&writer.interface, Root, about) catch return writer.err orelse error.WriteFailed;
    writer.interface.flush() catch return writer.err orelse error.WriteFailed;
}
