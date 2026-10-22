const std = @import("std");
const diagnostics = @import("base/diagnostics");
const cache_header = @import("base/cache/header");
const prepared_bundle = @import("phb/prepared");
const phb_read = @import("phb/read");
const cli_console = @import("interface/cli/console");
const cli_diagnostics = @import("interface/cli/diagnostics");
const cli_files = @import("interface/cli/files");

const Io = std.Io;
const Console = cli_console.Console;
const Escaped = diagnostics.Escaped;
const Diagnostics = diagnostics.Diagnostics;

pub fn load(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, console: Console) cli_console.Error!prepared_bundle.PreparedBundle {
    console.info("Loading bundle: {f}", .{Escaped{ .text = path }});
    var input = std.heap.ArenaAllocator.init(gpa);
    defer input.deinit();
    var diags: Diagnostics = .{ .arena = input.allocator(), .source = path };
    checkBundleHeader(io, path, diags.forSource(path)) catch |err| return cli_diagnostics.reportFailure(console, &diags, err);
    const bytes = try cli_files.readFile(io, input.allocator(), path, cli_files.max_input_bytes, console);
    return phb_read.read(arena, bytes, diags.forSource(path)) catch |err| cli_diagnostics.reportFailure(console, &diags, err);
}

fn checkBundleHeader(io: Io, path: []const u8, scope: diagnostics.Scope) diagnostics.InputError!void {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (st.kind != .file) return;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var head: [cache_header.header_len]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return;
    try cache_header.check(head[0..n], .phb, scope);
}
