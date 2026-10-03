const std = @import("std");
const Io = std.Io;
const core = @import("core.zig");
const civil = core.civil;
const Trajectory = @import("trajectory.zig").Trajectory;
const bundle = @import("bundle.zig");
const stage = @import("stage.zig");
const Diagnostics = core.diagnostics.Diagnostics;

pub const Console = struct {
    out: *Io.Writer,
    err: *Io.Writer,

    pub fn flush(self: Console) void {
        self.out.flush() catch {};
        self.err.flush() catch {};
    }

    pub fn print(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt, args) catch {};
    }

    pub fn info(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.print("[INFO]\t" ++ fmt ++ "\n", args);
    }

    pub fn warn(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.print("[WARNING]\t" ++ fmt ++ "\n", args);
    }

    pub fn fail(self: Console, comptime fmt: []const u8, args: anytype) void {
        self.err.print("[ERROR]\t" ++ fmt ++ "\n", args) catch {};
        self.flush();
    }
};

pub fn outOfMemory(console: Console) u8 {
    console.fail("Out of memory", .{});
    return 1;
}

pub const Tool = struct {
    name: []const u8,
    version: std.SemanticVersion,
};

pub const Value = enum { none, text, path };

pub const Option = struct {
    short: ?u8 = null,
    value: Value = .none,
    placeholder: []const u8 = "",
    help: []const u8,
};

pub const Input = struct {
    placeholder: []const u8,
    help: []const u8,
};

pub fn Options(comptime Name: type) type {
    return std.EnumArray(Name, Option);
}

pub const Refused = error{Refused};

pub const Refusal = union(enum) {
    unknown_option: []const u8,
    unknown_command: []const u8,
    unexpected: []const u8,
    foreign: struct { option: []const u8, command: []const u8 },
    twice: []const u8,
    no_path: []const u8,
    no_value: []const u8,
    expects: struct { option: []const u8, what: []const u8, got: ?[]const u8 },
    required: []const u8,

    pub fn format(self: Refusal, w: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .unknown_option => |arg| try w.print("Unknown option '{s}'", .{arg}),
            .unknown_command => |arg| try w.print("Unknown command '{s}'", .{arg}),
            .unexpected => |arg| try w.print("Unexpected argument '{s}'", .{arg}),
            .foreign => |f| try w.print("{s} is not an option of {s}", .{ f.option, f.command }),
            .twice => |option| try w.print("{s} is given twice", .{option}),
            .no_path => |option| try w.print("{s} requires a path", .{option}),
            .no_value => |option| try w.print("{s} requires a value", .{option}),
            .expects => |e| {
                try w.print("{s} expects {s}", .{ e.option, e.what });
                if (e.got) |got| try w.print(", got {s}", .{got});
            },
            .required => |what| try w.print("{s} is required", .{what}),
        }
    }
};

pub fn Scan(comptime Name: type, comptime options: Options(Name)) type {
    return struct {
        argv: []const []const u8,
        refusal: *Refusal,
        input: ?[]const u8,
        takes: std.EnumSet(Name) = .full,
        command: []const u8 = "",
        index: usize = 0,
        given: std.EnumSet(Name) = .empty,
        has_input: bool = false,

        const Self = @This();

        pub const Found = struct {
            name: Name,
            spelling: []const u8,
            value: []const u8,

            pub fn expects(self: Found, what: []const u8) Refusal {
                return .{ .expects = .{ .option = self.spelling, .what = what, .got = self.value } };
            }

            pub fn number(self: Found) f64 {
                return real(self.value) orelse std.math.nan(f64);
            }
        };

        pub const Item = union(enum) { input: []const u8, option: Found };

        pub fn next(self: *Self) Refused!?Item {
            if (self.index == self.argv.len) {
                if (self.input) |placeholder| {
                    if (!self.has_input) return self.refuse(.{ .required = placeholder });
                }
                return null;
            }
            const arg = self.argv[self.index];
            self.index += 1;
            if (!isOption(arg)) {
                if (self.input == null or self.has_input) return self.refuse(.{ .unexpected = arg });
                self.has_input = true;
                return .{ .input = arg };
            }
            const name = find(Name, options, arg) orelse return self.refuse(.{ .unknown_option = arg });
            if (!self.takes.contains(name)) return self.refuse(.{ .foreign = .{ .option = arg, .command = self.command } });
            const value = options.get(name).value;
            if (value == .none) return .{ .option = .{ .name = name, .spelling = arg, .value = "" } };
            if (self.given.contains(name)) return self.refuse(.{ .twice = arg });
            self.given.insert(name);
            const rest = self.argv[self.index..];
            if (!takesNext(value, rest)) return self.refuse(if (value == .path) .{ .no_path = arg } else .{ .no_value = arg });
            self.index += 1;
            return .{ .option = .{ .name = name, .spelling = arg, .value = rest[0] } };
        }

        pub fn refuse(self: *const Self, refusal: Refusal) Refused {
            self.refusal.* = refusal;
            return error.Refused;
        }

        pub fn expects(self: *const Self, found: Found, what: []const u8) Refused {
            return self.refuse(found.expects(what));
        }

        pub fn integer(self: *const Self, comptime T: type, comptime min: T, comptime max: T, found: Found) Refused!T {
            const range = std.fmt.comptimePrint("{d}..{d}", .{ min, max });
            const n = decimal(T, found.value) orelse return self.expects(found, range);
            return if (n >= min and n <= max) n else self.expects(found, range);
        }

        pub fn word(self: *const Self, comptime E: type, found: Found) Refused!E {
            return core.dictionary.parse(E, found.value) orelse self.expects(found, comptime core.dictionary.choices(E));
        }
    };
}

pub fn decimal(comptime T: type, text: []const u8) ?T {
    if (std.mem.findNone(u8, text, "0123456789") != null) return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

pub fn real(text: []const u8) ?f64 {
    if (std.mem.startsWith(u8, text, "+") or std.mem.findNone(u8, text, "0123456789.eE+-") != null) return null;
    return std.fmt.parseFloat(f64, text) catch null;
}

pub fn optionLines(comptime tool: Tool, comptime Name: type, comptime options: Options(Name), comptime input: ?Input) []const u8 {
    comptime {
        const first: []const Row = if (input) |i| &.{.{ .label = i.placeholder, .help = i.help }} else &.{};
        const rows = first ++ labelled(Name, options) ++ labelled(Request, requests(tool));
        var width: usize = 0;
        for (rows) |row| width = @max(width, row.label.len);
        var text: []const u8 = "";
        for (rows) |row| text = text ++ "  " ++ row.label ++ " " ** (width + 3 - row.label.len) ++ row.help ++ "\n";
        return text;
    }
}

const Row = struct { label: []const u8, help: []const u8 };

fn labelled(comptime Name: type, comptime options: Options(Name)) []const Row {
    comptime {
        var rows: []const Row = &.{};
        for (std.enums.values(Name)) |name| {
            const option = options.get(name);
            const short = if (option.short) |letter| "-" ++ [_]u8{letter} ++ ", " else "    ";
            const value = if (option.placeholder.len > 0) " " ++ option.placeholder else "";
            rows = rows ++ [_]Row{.{ .label = short ++ long(name) ++ value, .help = option.help }};
        }
        return rows;
    }
}

fn long(comptime name: anytype) []const u8 {
    comptime {
        var text = @tagName(name)[0..].*;
        std.mem.replaceScalar(u8, &text, '_', '-');
        const spelled = text;
        return "--" ++ &spelled;
    }
}

fn find(comptime Name: type, comptime options: Options(Name), arg: []const u8) ?Name {
    inline for (comptime std.enums.values(Name)) |name| {
        if (std.mem.eql(u8, arg, comptime long(name))) return name;
        if (comptime options.get(name).short) |letter| {
            if (std.mem.eql(u8, arg, &[_]u8{ '-', letter })) return name;
        }
    }
    return null;
}

fn takesNext(value: Value, rest: []const []const u8) bool {
    return switch (value) {
        .none => false,
        .text => rest.len > 0,
        .path => rest.len > 0 and !isOption(rest[0]),
    };
}

fn isOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

const Request = enum { version, help };

fn requests(comptime tool: Tool) Options(Request) {
    const v = tool.version;
    return .init(.{
        .version = .{ .short = 'v', .help = std.fmt.comptimePrint("prints {s} {d}.{d}.{d} and exits 0", .{ tool.name, v.major, v.minor, v.patch }) },
        .help = .{ .short = 'h', .help = "prints the usage and exits 0; no argument does the same" },
    });
}

fn wanted(comptime tool: Tool, comptime Name: type, comptime options: Options(Name), argv: []const []const u8) ?Request {
    if (argv.len == 0) return .help;
    var request: ?Request = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (find(Request, requests(tool), argv[i])) |asked| switch (asked) {
            .help => return .help,
            .version => request = .version,
        } else if (find(Name, options, argv[i])) |name| {
            if (takesNext(options.get(name).value, argv[i + 1 ..])) i += 1;
        }
    }
    return request;
}

pub fn main(init: std.process.Init, comptime Line: type, comptime run: fn (std.mem.Allocator, Io, Line.Args, Console) u8) !void {
    const arena = init.arena.allocator();
    const all = try init.minimal.args.toSlice(arena);
    const argv = all[@min(all.len, 1)..];
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buffer);
    const console: Console = .{ .out = &stdout_writer.interface, .err = &stderr_writer.interface };
    var refusal: Refusal = undefined;
    const status: u8 = dispatch: {
        if (wanted(Line.tool, Line.Name, Line.options, argv)) |request| {
            switch (request) {
                .help => console.print("{s}", .{Line.usage}),
                .version => {
                    const v = Line.tool.version;
                    console.print("{s} {d}.{d}.{d}\n", .{ Line.tool.name, v.major, v.minor, v.patch });
                },
            }
            break :dispatch 0;
        }

        const args = Line.parse(argv, &refusal) catch {
            console.fail("{f}", .{refusal});
            break :dispatch 1;
        };
        break :dispatch run(init.gpa, init.io, args, console);
    };
    console.flush();
    const lost = stdout_writer.err != null or stderr_writer.err != null;
    if (status != 0 or lost) std.process.exit(if (status != 0) status else 1);
}

pub const max_input_bytes: usize = 1 << 30;
const utf8_bom = "\xEF\xBB\xBF";

pub fn readFile(io: Io, arena: std.mem.Allocator, path: []const u8, max_bytes: usize, console: Console) std.mem.Allocator.Error!?[]u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes + 1)) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (e == error.StreamTooLong) {
            const cap = mib(max_bytes);
            if (Io.Dir.cwd().statFile(io, path, .{})) |st| {
                console.fail("Cannot read {s}: the file is {d:.1} MiB; this input may be at most {d:.0} MiB", .{ path, mib(st.size), cap });
            } else |_| console.fail("Cannot read {s}: this input may be at most {d:.0} MiB", .{ path, cap });
        } else console.fail("Cannot read {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    return if (std.mem.startsWith(u8, bytes, utf8_bom)) bytes[utf8_bom.len..] else bytes;
}

pub fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

pub fn cannotWrite(console: Console, path: []const u8, e: anyerror) void {
    console.fail("Cannot write {s}: {s}", .{ path, @errorName(e) });
}

pub fn writeFile(io: Io, path: []const u8, bytes: []const u8, console: Console) bool {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |e| {
        cannotWrite(console, path, e);
        return false;
    };
    return true;
}

pub const FileWriter = struct {
    file: Io.File,
    writer: Io.File.Writer,
    buffer: [64 * 1024]u8,

    pub fn open(self: *FileWriter, io: Io, path: []const u8) Io.File.OpenError!void {
        self.file = try Io.Dir.cwd().createFile(io, path, .{});
        self.writer = Io.File.Writer.init(self.file, io, &self.buffer);
    }

    pub fn interface(self: *FileWriter) *Io.Writer {
        return &self.writer.interface;
    }

    pub fn finish(self: *FileWriter, io: Io) (Io.File.Writer.Error || Io.Writer.Error)!void {
        defer self.file.close(io);
        self.writer.interface.flush() catch |e| return self.writer.err orelse e;
        if (self.writer.err) |e| return e;
    }
};

pub fn withExtension(arena: std.mem.Allocator, path: []const u8, extension: []const u8) error{OutOfMemory}![]const u8 {
    const ext = std.Io.Dir.path.extension(path);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ path[0 .. path.len - ext.len], extension });
}

pub fn printDiagnostics(console: Console, diags: *const Diagnostics) void {
    for (diags.slice()) |d| switch (d.severity) {
        .err => console.fail("{f}", .{d}),
        .warning => console.warn("{f}", .{d}),
    };
    console.flush();
}

fn checkBundleHeader(io: Io, path: []const u8, scope: core.diagnostics.Scope) core.diagnostics.InputError!void {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (st.kind != .file) return;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    var head: [bundle.format.header_len]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return;
    try bundle.format.checkHeader(head[0..n], scope);
}

pub fn loadBundle(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, console: Console) ?bundle.Bundle {
    console.info("Loading bundle: {s}", .{path});
    var input = std.heap.ArenaAllocator.init(gpa);
    defer input.deinit();
    var diags: Diagnostics = .{ .arena = input.allocator(), .source = path };
    checkBundleHeader(io, path, diags.forSource(path)) catch |e| {
        if (e == error.OutOfMemory) {
            _ = outOfMemory(console);
        } else printDiagnostics(console, &diags);
        return null;
    };
    const bytes = (readFile(io, input.allocator(), path, max_input_bytes, console) catch {
        _ = outOfMemory(console);
        return null;
    }) orelse return null;
    return bundle.format.read(arena, bytes, diags.forSource(path)) catch |e| {
        if (e == error.OutOfMemory) {
            _ = outOfMemory(console);
            return null;
        }
        printDiagnostics(console, &diags);
        return null;
    };
}

pub fn reportTrajectory(console: Console, traj: *const Trajectory, file: []const u8) void {
    if (traj.name.len > 0) {
        console.info("Trajectory {s} ({s}): {d} knots over {d:.3} s", .{ traj.name, file, traj.knots.len, traj.duration() });
    } else console.info("Trajectory {s}: {d} knots over {d:.3} s", .{ file, traj.knots.len, traj.duration() });
}

pub fn reportSpan(console: Console, span: bundle.Span, leap: civil.Leap) void {
    const gps = span.start.printed(null);
    const utc = span.start.printed(leap);
    if (span.leap_change) |at| {
        console.info("Run: {d} ms from {f}, {f}; leap seconds {d}, then {d} from {f}", .{ span.epochs, gps, utc, span.leap_seconds, span.leap_seconds_after, at.printed(null) });
    } else console.info("Run: {d} ms from {f}, {f}; leap seconds {d}", .{ span.epochs, gps, utc, span.leap_seconds });
}

pub fn reportNavigation(console: Console, b: *const bundle.Bundle) void {
    const set = &b.navigation;
    console.info("Navigation data: {d} Keplerian and {d} GLONASS records", .{ set.kepler.len, set.glonass.len });
    reportAntenna(console, b);
    if (set.precise) |product| reportPrecise(console, product);
}

pub fn reportCoverage(console: Console, b: *const bundle.Bundle) void {
    for (b.plan.timelines) |timeline| {
        if (b.scenario.listedSignalOf(timeline.sat) != null) break;
    } else return;
    const covered = b.plan.coveredMs(&b.scenario, null);
    if (covered >= b.epochs()) return;
    console.warn("No satellite of a listed signal flies a record from {d:.3} s into the run: nothing is transmitted from there on", .{@as(f64, @floatFromInt(covered)) / 1000.0});
}

fn reportPrecise(console: Console, product: *const bundle.precise.Product) void {
    console.info("Precise product: {d} satellites at {d} s", .{ product.satelliteCount(), product.interval_s });
}

fn reportAntenna(console: Console, b: *const bundle.Bundle) void {
    if (b.navigation.antenna == null) return;
    var with: usize = 0;
    var without: usize = 0;
    for (b.plan.timelines) |timeline| {
        if (b.navigation.phaseCentre(timeline.sat, b.scenario.start) == null) without += 1 else with += 1;
    }
    console.info("Antenna offsets: {d} satellites with a phase centre per band, {d} without", .{ with, without });
}

pub fn reportServices(console: Console, s: *const bundle.scenario.Scenario) void {
    if (s.has) |h| console.info("HAS MT1 on E6-B: status {s}, clocks every {d} s, orbits and biases every {d} s", .{ h.status.name(), h.clock_interval_s, h.orbit_interval_s });
    if (s.ppp_b2b) |p| console.info("PPP-B2b on the BDS-3 GEO B2b: clocks every {d} s, orbit cycles of {d} s", .{ p.clock_interval_s, p.orbit_interval_s });
}

pub fn printIonosphere(console: Console, ionosphere: *const stage.ionosphere.Ionosphere) void {
    console.info("Ionosphere: {s}", .{ionosphere.requested.name()});
    var it = ionosphere.enabled.iterator();
    while (it.next()) |system| {
        const origin: []const u8 = switch (ionosphere.sources.get(system)) {
            .scenario => "the scenario",
            .navigation => "the navigation data",
            .built_in => "the built-in set",
            .none => "",
        };
        switch (ionosphere.models.get(system).*) {
            .none => console.info("Ionosphere {s}: none", .{system.name()}),
            .klobuchar => |k| {
                const name: []const u8 = if (ionosphere.requested == .auto and system == .glo) "Klobuchar substitute" else "Klobuchar";
                console.info("Ionosphere {s}: {s}, alpha {e:.3} {e:.3} {e:.3} {e:.3}, beta {e:.3} {e:.3} {e:.3} {e:.3} ({s})", .{ system.name(), name, k.alpha[0], k.alpha[1], k.alpha[2], k.alpha[3], k.beta[0], k.beta[1], k.beta[2], k.beta[3], origin });
            },
            .bds_klobuchar => |b| {
                const k = b.coefficients;
                console.info("Ionosphere {s}: BDS Klobuchar, alpha {e:.3} {e:.3} {e:.3} {e:.3}, beta {e:.3} {e:.3} {e:.3} {e:.3} ({s})", .{ system.name(), k.alpha[0], k.alpha[1], k.alpha[2], k.alpha[3], k.beta[0], k.beta[1], k.beta[2], k.beta[3], origin });
            },
            .nequick => |n| console.info("Ionosphere {s}: NeQuick G, ai0 {d} ai1 {d} ai2 {d} ({s})", .{ system.name(), n.coefficients.ai0, n.coefficients.ai1, n.coefficients.ai2, origin }),
            .bdgim => |m| console.info("Ionosphere {s}: BDGIM, alpha {d} {d} {d} {d} {d} {d} {d} {d} {d} TECu ({s})", .{ system.name(), m.alpha[0], m.alpha[1], m.alpha[2], m.alpha[3], m.alpha[4], m.alpha[5], m.alpha[6], m.alpha[7], m.alpha[8], origin }),
        }
    }
}
