const build_info = @import("build_info");
const cli_arguments = @import("interface/cli/arguments");

pub const tool: cli_arguments.Tool = .{ .name = "pharos-pack", .version = build_info.version };

pub const Name = enum { output, dry_run };

pub const options: cli_arguments.Options(Name) = .init(.{
    .output = .{ .short = 'o', .value = .path, .placeholder = "<FILE>", .help = "the bundle; default: the scenario file's name with .phb" },
    .dry_run = .{ .help = "reads and checks the scenario and its files; writes no file" },
});

const input: cli_arguments.Input = .{ .placeholder = "<scenario.json>", .help = "the scenario JSON" };

pub const usage =
    \\pharos-pack - packs a Pharos scenario with its navigation data
    \\
    \\Usage: pharos-pack <scenario.json> [options]
    \\
    \\Options:
    \\
++ cli_arguments.optionLines(tool, Name, options, input) ++
    \\
    \\Examples:
    \\  pharos-pack scenario.json
    \\  pharos-pack scenario.json -o run.phb && pharos-run run.phb -t
    \\
;

pub const Args = struct {
    input: []const u8,
    operation: union(enum) { check, write: ?[]const u8 },
};

pub fn parse(argv: []const []const u8, refusal: *cli_arguments.Refusal) cli_arguments.Refused!Args {
    var scan: cli_arguments.Scan(Name, options) = .{ .argv = argv, .refusal = refusal, .input = input.placeholder };
    var path: []const u8 = undefined;
    var output: ?[]const u8 = null;
    var check = false;
    while (try scan.next()) |item| switch (item) {
        .input => |given| path = given,
        .option => |o| switch (o.name) {
            .output => output = o.value,
            .dry_run => check = true,
        },
    };
    return .{ .input = path, .operation = if (check) .check else .{ .write = output } };
}
