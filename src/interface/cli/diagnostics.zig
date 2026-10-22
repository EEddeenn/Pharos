const cli_console = @import("interface/cli/console");
const diagnostics = @import("base/diagnostics");

const Console = cli_console.Console;
const Diagnostics = diagnostics.Diagnostics;

pub fn printDiagnostics(console: Console, diags: *const Diagnostics) void {
    for (diags.slice()) |d| switch (d.severity) {
        .err => console.fail("{f}", .{d}),
        .warning => console.warn("{f}", .{d}),
        .note => console.info("{f}", .{d}),
    };
    console.flush();
}

pub fn reportFailure(console: Console, diags: *const Diagnostics, err: diagnostics.LoadError) cli_console.Error {
    printDiagnostics(console, diags);
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Reported;
}
