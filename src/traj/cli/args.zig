const std = @import("std");
const pharos_traj = @import("pharos_traj");
const cli = pharos_traj.cli;
const Placement = pharos_traj.static.Placement;

pub const tool: cli.Tool = .{ .name = "pharos-traj", .version = pharos_traj.version };

pub const Name = enum { output, name, lla, ecef, duration };

pub const options: cli.Options(Name) = .init(.{
    .output = .{ .short = 'o', .value = .path, .placeholder = "<FILE>", .help = "the output file" },
    .name = .{ .value = .text, .placeholder = "<TEXT>", .help = "the trajectory's name, UTF-8" },
    .lla = .{ .value = .text, .placeholder = "<LAT,LON,ALTITUDE>", .help = "degrees, and metres above the geoid" },
    .ecef = .{ .value = .text, .placeholder = "<X,Y,Z>", .help = "ECEF metres" },
    .duration = .{ .value = .text, .placeholder = "<SECONDS>", .help = std.fmt.comptimePrint("the length of the stay, from {d} to {d}", .{ pharos_traj.static.duration_range.min, pharos_traj.static.duration_range.max }) },
});

const Command = enum { build, static, info, check, @"export" };

const Takes = struct { input: ?[]const u8, options: std.EnumSet(Name) };

const commands: std.EnumArray(Command, Takes) = .init(.{
    .build = .{ .input = "<trajectory.json>", .options = .initMany(&.{ .output, .name }) },
    .static = .{ .input = null, .options = .initMany(&.{ .lla, .ecef, .duration, .output, .name }) },
    .info = .{ .input = "<file.pht>", .options = .empty },
    .check = .{ .input = "<file.pht>", .options = .empty },
    .@"export" = .{ .input = "<file.pht>", .options = .initOne(.output) },
});

pub const usage =
    \\pharos-traj - builds, checks and visualizes Pharos trajectories
    \\
    \\Usage: pharos-traj <command> [arguments]
    \\
    \\Commands:
    \\  build <trajectory.json> [-o <FILE>] [--name <TEXT>]
    \\      the path of a trajectory plan as a PHT; default: the source file's name with .pht
    \\  static (--lla <LAT,LON,ALTITUDE> | --ecef <X,Y,Z>) --duration <SECONDS> -o <FILE> [--name <TEXT>]
    \\      a receiver at rest
    \\  info <file.pht>
    \\      the name, the knots, the duration and the end positions
    \\  check <file.pht>
    \\      the speed, acceleration, jerk and altitude ranges, and the steps
    \\  export <file.pht> [-o <FILE>]
    \\      the path as a KML line; default: the trajectory file's name with .kml
    \\
    \\Options:
    \\
++ cli.optionLines(tool, Name, usedBy(), null) ++
    \\
    \\Examples:
    \\  pharos-traj build trajectory.json
    \\  pharos-traj static --lla 30.5292,114.3642,40 --duration 600 -o wuhan.pht
    \\  pharos-traj check drive.pht
    \\
;

fn usedBy() cli.Options(Name) {
    comptime {
        var shown = options;
        for (std.enums.values(Name)) |name| {
            var users: []const u8 = "";
            for (std.enums.values(Command)) |command| {
                if (commands.get(command).options.contains(name)) users = users ++ (if (users.len == 0) "" else ", ") ++ @tagName(command);
            }
            shown.getPtr(name).help = users ++ ": " ++ options.get(name).help;
        }
        return shown;
    }
}

pub const Args = union(Command) {
    build: Build,
    static: Static,
    info: []const u8,
    check: []const u8,
    @"export": Export,
};

pub const Build = struct { input: []const u8, output: ?[]const u8, name: ?[]const u8 };
pub const Static = struct { at: Parsed(Placement), duration_s: Parsed(f64), output: []const u8, name: ?[]const u8 };
pub const Export = struct { input: []const u8, output: ?[]const u8 };

fn Parsed(comptime T: type) type {
    return struct { value: T, found: cli.Scan(Name, options).Found };
}

const Given = struct {
    input: []const u8 = undefined,
    output: ?[]const u8 = null,
    name: ?[]const u8 = null,
    at: ?Parsed(Placement) = null,
    duration_s: ?Parsed(f64) = null,
};

pub fn parse(argv: []const []const u8, refusal: *cli.Refusal) cli.Refused!Args {
    const command = std.meta.stringToEnum(Command, argv[0]) orelse {
        refusal.* = .{ .unknown_command = argv[0] };
        return error.Refused;
    };
    const takes = commands.get(command);
    var scan: cli.Scan(Name, options) = .{
        .argv = argv[1..],
        .refusal = refusal,
        .input = takes.input,
        .takes = takes.options,
        .command = argv[0],
    };
    var given: Given = .{};
    while (try scan.next()) |item| switch (item) {
        .input => |path| given.input = path,
        .option => |o| switch (o.name) {
            .output => given.output = o.value,
            .name => {
                if (!std.unicode.utf8ValidateSlice(o.value)) return scan.refuse(.{ .expects = .{ .option = o.spelling, .what = "UTF-8 text", .got = null } });
                given.name = o.value;
            },
            .lla, .ecef => {
                if (given.at != null) return scan.refuse(.{ .twice = "--lla or --ecef" });
                const point = triple(o.value) orelse return scan.expects(o, if (o.name == .lla) "latitude,longitude,altitude" else "x,y,z");
                given.at = .{
                    .value = if (o.name == .lla)
                        .{ .lla = .{ .lat_deg = point[0], .lon_deg = point[1], .altitude_m = point[2] } }
                    else
                        .{ .ecef = .fromArray(point) },
                    .found = o,
                };
            },
            .duration => given.duration_s = .{ .value = o.number(), .found = o },
        },
    };
    return switch (command) {
        .build => .{ .build = .{ .input = given.input, .output = given.output, .name = given.name } },
        .static => .{ .static = .{
            .at = given.at orelse return scan.refuse(.{ .required = "--lla or --ecef" }),
            .duration_s = given.duration_s orelse return scan.refuse(.{ .required = "--duration" }),
            .output = given.output orelse return scan.refuse(.{ .required = "-o" }),
            .name = given.name,
        } },
        .info => .{ .info = given.input },
        .check => .{ .check = given.input },
        .@"export" => .{ .@"export" = .{ .input = given.input, .output = given.output } },
    };
}

fn triple(text: []const u8) ?[3]f64 {
    var out: [3]f64 = undefined;
    var parts = std.mem.splitScalar(u8, text, ',');
    for (&out) |*v| v.* = cli.real(parts.next() orelse return null) orelse return null;
    return if (parts.next() == null) out else null;
}
