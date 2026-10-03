const pharos_pack = @import("pharos_pack");
const cli = pharos_pack.cli;

pub const tool: cli.Tool = .{ .name = "pharos-pack", .version = pharos_pack.version };

pub const Name = enum { output, dry_run };

pub const options: cli.Options(Name) = .init(.{
    .output = .{ .short = 'o', .value = .path, .placeholder = "<FILE>", .help = "the bundle; default: the scenario file's name with .phb" },
    .dry_run = .{ .help = "reads and checks the scenario and its files; writes no file" },
});

const input: cli.Input = .{ .placeholder = "<scenario.json>", .help = "the scenario JSON" };

pub const usage =
    \\pharos-pack - packs a Pharos scenario with its navigation data
    \\
    \\Usage: pharos-pack <scenario.json> [options]
    \\
    \\Options:
    \\
++ cli.optionLines(tool, Name, options, input) ++
    \\
    \\Examples:
    \\  pharos-pack scenario.json
    \\  pharos-pack scenario.json -o run.phb && pharos-run run.phb -t
    \\
;

pub const Args = struct {
    input: []const u8,
    output: ?[]const u8 = null,
    dry_run: bool = false,
};

pub fn parse(argv: []const []const u8, refusal: *cli.Refusal) cli.Refused!Args {
    var scan: cli.Scan(Name, options) = .{ .argv = argv, .refusal = refusal, .input = input.placeholder };
    var args: Args = .{ .input = undefined };
    while (try scan.next()) |item| switch (item) {
        .input => |path| args.input = path,
        .option => |o| switch (o.name) {
            .output => args.output = o.value,
            .dry_run => args.dry_run = true,
        },
    };
    return args;
}
