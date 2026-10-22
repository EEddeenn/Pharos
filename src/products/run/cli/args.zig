const std = @import("std");
const build_info = @import("build_info");
const dictionary = @import("base/text/dictionary");
const engine_run = @import("products/run/engine/run");
const cli_arguments = @import("interface/cli/arguments");
const gain = @import("products/run/synthesis/gain");

const NoiseMode = engine_run.NoiseMode;
const Epoch = @import("domain/time/gps").Epoch;

pub const tool: cli_arguments.Tool = .{ .name = "pharos-run", .version = build_info.version };

pub const Name = enum { output, tag, workers, seed, noise, gain, seek, dump, dry_run };

pub const options: cli_arguments.Options(Name) = .init(.{
    .output = .{ .short = 'o', .value = .path, .placeholder = "<FILE>", .help = "the sample file; default: the bundle's name with .bin" },
    .tag = .{ .short = 't', .help = "write the .tag sidecar" },
    .workers = .{ .value = .text, .placeholder = "<N>", .help = "the threads a pull uses, the calling one among them; default: 0, one per hardware thread" },
    .seed = .{ .value = .text, .placeholder = "<N>", .help = "the noise seed; default: 0" },
    .noise = .{ .value = .text, .placeholder = "<MODE>", .help = "the noise stream, " ++ dictionary.choices(NoiseMode) ++ "; default: counter" },
    .gain = .{ .value = .text, .placeholder = "<DB>", .help = std.fmt.comptimePrint("a constant digital gain in dB, {d} to {d}; default: adaptive, the AGC", .{ gain.Db.min.db, gain.Db.max.db }) },
    .seek = .{ .value = .text, .placeholder = "<EPOCH>", .help = "start the file at this epoch, in ms from the run start; needs --gain" },
    .dump = .{ .value = .path, .placeholder = "<DIR>", .help = "write the stage dumps into DIR" },
    .dry_run = .{ .help = "creates the run, enters it at --seek, prints its report; writes no file" },
});

const input: cli_arguments.Input = .{ .placeholder = "<bundle.phb>", .help = "the bundle, from pharos-pack" };

pub const usage =
    \\pharos-run - generates the IF samples of a Pharos bundle
    \\
    \\Usage: pharos-run <bundle.phb> [options]
    \\
    \\Options:
    \\
++ cli_arguments.optionLines(tool, Name, options, input) ++
    \\
    \\Examples:
    \\  pharos-pack scenario.json && pharos-run scenario.phb
    \\  pharos-run run.phb --output mydata.bin -t
    \\
;

pub const Args = struct {
    input: []const u8,
    options: engine_run.Options = .{},
    seek: ?Epoch = null,
    operation: union(enum) { check, write: Write },
};

pub const Write = struct {
    output: ?[]const u8 = null,
    tag: bool = false,
    dump: ?[]const u8 = null,
};

const gain_range = std.fmt.comptimePrint("from {d} to {d} dB", .{ gain.Db.min.db, gain.Db.max.db });

pub fn parse(argv: []const []const u8, refusal: *cli_arguments.Refusal) cli_arguments.Refused!Args {
    var scan: cli_arguments.Scan(Name, options) = .{ .argv = argv, .refusal = refusal, .input = input.placeholder };
    var args: Args = .{ .input = undefined, .operation = .check };
    var write: Write = .{};
    var check = false;
    while (try scan.next()) |item| switch (item) {
        .input => |path| args.input = path,
        .option => |o| switch (o.name) {
            .output => write.output = o.value,
            .tag => write.tag = true,
            .workers => args.options.workers = try scan.integer(u32, 0, std.math.maxInt(u32), o),
            .seed => args.options.seed = try scan.integer(u64, 0, std.math.maxInt(u64), o),
            .noise => args.options.noise = try scan.word(NoiseMode, o),
            .gain => args.options.gain = .{ .constant = gain.Db.fromValue(try scan.number(o)) orelse return scan.outside(o, gain_range) },
            .seek => args.seek = .{ .ms = try scan.integer(u64, 0, std.math.maxInt(u64), o) },
            .dump => write.dump = o.value,
            .dry_run => check = true,
        },
    };
    if (args.seek != null and args.options.gain == .adaptive) return scan.refuse(.{ .requires = .{ .option = "--seek", .required = "--gain" } });
    args.operation = if (check) .check else .{ .write = write };
    return args;
}
