const std = @import("std");
const pharos_run = @import("pharos_run");
const cli = pharos_run.cli;
const engine = pharos_run.engine;
const NoiseMode = engine.run.NoiseMode;
const gain = pharos_run.synth.gain;
const Epoch = pharos_run.core.time.Epoch;

pub const tool: cli.Tool = .{ .name = "pharos-run", .version = pharos_run.version };

pub const Name = enum { output, tag, workers, seed, noise, gain, seek, dump, dry_run };

pub const options: cli.Options(Name) = .init(.{
    .output = .{ .short = 'o', .value = .path, .placeholder = "<FILE>", .help = "the sample file; default: the bundle's name with .bin" },
    .tag = .{ .short = 't', .help = "write the .tag sidecar" },
    .workers = .{ .value = .text, .placeholder = "<N>", .help = "the threads a pull uses, the calling one among them; default: 0, one per hardware thread" },
    .seed = .{ .value = .text, .placeholder = "<N>", .help = "the noise seed; default: 0" },
    .noise = .{ .value = .text, .placeholder = "<MODE>", .help = "the noise stream, " ++ pharos_run.core.dictionary.choices(NoiseMode) ++ "; default: counter" },
    .gain = .{ .value = .text, .placeholder = "<DB>", .help = std.fmt.comptimePrint("a constant digital gain in dB, {d} to {d}; default: adaptive, the AGC", .{ gain.Db.min.db, gain.Db.max.db }) },
    .seek = .{ .value = .text, .placeholder = "<EPOCH>", .help = "start the file at this epoch, in ms from the run start; needs --gain" },
    .dump = .{ .value = .path, .placeholder = "<DIR>", .help = "write the stage dumps into DIR" },
    .dry_run = .{ .help = "creates the run, enters it at --seek, prints its report; writes no file" },
});

const input: cli.Input = .{ .placeholder = "<bundle.phb>", .help = "the bundle, from pharos-pack" };

pub const usage =
    \\pharos-run - generates the IF samples of a Pharos bundle
    \\
    \\Usage: pharos-run <bundle.phb> [options]
    \\
    \\Options:
    \\
++ cli.optionLines(tool, Name, options, input) ++
    \\
    \\Examples:
    \\  pharos-pack scenario.json && pharos-run scenario.phb
    \\  pharos-run run.phb --output mydata.bin -t
    \\
;

pub const Args = struct {
    input: []const u8,
    output: ?[]const u8 = null,
    tag: bool = false,
    seek: ?Epoch = null,
    dump: ?[]const u8 = null,
    dry_run: bool = false,
    options: engine.run.Options = .{},
};

const gain_range = std.fmt.comptimePrint("{d}..{d} dB", .{ gain.Db.min.db, gain.Db.max.db });

pub fn parse(argv: []const []const u8, refusal: *cli.Refusal) cli.Refused!Args {
    var scan: cli.Scan(Name, options) = .{ .argv = argv, .refusal = refusal, .input = input.placeholder };
    var args: Args = .{ .input = undefined };
    while (try scan.next()) |item| switch (item) {
        .input => |path| args.input = path,
        .option => |o| switch (o.name) {
            .output => args.output = o.value,
            .tag => args.tag = true,
            .workers => args.options.workers = try scan.integer(u32, 0, std.math.maxInt(u32), o),
            .seed => args.options.seed = try scan.integer(u64, 0, std.math.maxInt(u64), o),
            .noise => args.options.noise = try scan.word(NoiseMode, o),
            .gain => args.options.gain = gain.Db.fromValue(o.number()) orelse return scan.expects(o, gain_range),
            .seek => args.seek = .{ .ms = try scan.integer(u64, 0, std.math.maxInt(u64), o) },
            .dump => args.dump = o.value,
            .dry_run => args.dry_run = true,
        },
    };
    return args;
}
