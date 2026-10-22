const std = @import("std");
const build_info = @import("build_info");
const cli_arguments = @import("interface/cli/arguments");

const Created = @import("products/obs/output/session").Created;
const Epoch = @import("domain/time/gps").Epoch;

pub const tool: cli_arguments.Tool = .{ .name = "pharos-obs", .version = build_info.version };

pub const Name = enum { observation, position, created, seek, dry_run };

pub const options: cli_arguments.Options(Name) = .init(.{
    .observation = .{ .value = .path, .placeholder = "<FILE>", .help = "the observation file; default: the bundle's name with .obs" },
    .position = .{ .value = .path, .placeholder = "<FILE>", .help = "the position file; default: the bundle's name with .ecef, .lla or .kml" },
    .created = .{ .value = .text, .placeholder = "<SECONDS>", .help = std.fmt.comptimePrint("the observation file's creation time, in seconds since 1970-01-01 00:00:00 UTC, {d} to {d}; default: the wall clock", .{ Created.min.unix_s, Created.max.unix_s }) },
    .seek = .{ .value = .text, .placeholder = "<EPOCH>", .help = "start each file at its first epoch at or after this one, in ms from the run start" },
    .dry_run = .{ .help = "creates each file the bundle declares, prints its report; writes no file" },
});

const input: cli_arguments.Input = .{ .placeholder = "<bundle.phb>", .help = "the bundle, from pharos-pack" };

pub const usage =
    \\pharos-obs - writes the observation and position files of a Pharos bundle
    \\
    \\Usage: pharos-obs <bundle.phb> [options]
    \\
    \\Options:
    \\
++ cli_arguments.optionLines(tool, Name, options, input) ++
    \\
    \\Each file is written when the bundle declares it.
    \\
    \\Examples:
    \\  pharos-pack scenario.json && pharos-obs scenario.phb
    \\  pharos-obs run.phb --observation rover.obs --position rover.kml
    \\
;

pub const Args = struct {
    input: []const u8,
    observation: ?[]const u8 = null,
    position: ?[]const u8 = null,
    created: ?Created = null,
    seek: ?Epoch = null,
    mode: Mode = .write,
};

pub const Mode = enum { check, write };

const created_range = std.fmt.comptimePrint("from {d} to {d} seconds", .{ Created.min.unix_s, Created.max.unix_s });

pub fn parse(argv: []const []const u8, refusal: *cli_arguments.Refusal) cli_arguments.Refused!Args {
    var scan: cli_arguments.Scan(Name, options) = .{ .argv = argv, .refusal = refusal, .input = input.placeholder };
    var args: Args = .{ .input = undefined };
    while (try scan.next()) |item| switch (item) {
        .input => |path| args.input = path,
        .option => |o| switch (o.name) {
            .observation => args.observation = o.value,
            .position => args.position = o.value,
            .created => args.created = creationTime(o.value) orelse return scan.outside(o, created_range),
            .seek => args.seek = .{ .ms = try scan.integer(u64, 0, std.math.maxInt(u64), o) },
            .dry_run => args.mode = .check,
        },
    };
    return args;
}

fn creationTime(text: []const u8) ?Created {
    return Created.fromUnixSeconds(cli_arguments.decimal(i64, text) orelse return null);
}
