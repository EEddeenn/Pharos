const std = @import("std");
const dictionary = @import("base/text/dictionary");
const diagnostics = @import("base/diagnostics");

const Io = std.Io;
const Escaped = diagnostics.Escaped;

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

pub const Refused = error{Refused};

/// An argument that matched no option or command, and a value, are the user's text, quoted escaped; the other texts
/// are options and commands that matched, or Pharos's own words.
pub const Refusal = union(enum) {
    unknown_option: []const u8,
    unknown_command: []const u8,
    unexpected: []const u8,
    foreign: struct { option: []const u8, command: []const u8 },
    twice: []const u8,
    no_path: []const u8,
    no_value: []const u8,
    requires: struct { option: []const u8, required: []const u8 },
    expects: struct { option: []const u8, what: []const u8, got: ?[]const u8 },
    outside: struct { option: []const u8, range: []const u8, got: []const u8 },
    required: []const u8,

    pub fn format(self: Refusal, w: *Io.Writer) Io.Writer.Error!void {
        switch (self) {
            .unknown_option => |arg| try w.print("Unknown option '{f}'", .{Escaped{ .text = arg }}),
            .unknown_command => |arg| try w.print("Unknown command '{f}'", .{Escaped{ .text = arg }}),
            .unexpected => |arg| try w.print("Unexpected argument '{f}'", .{Escaped{ .text = arg }}),
            .foreign => |f| try w.print("{s} is not an option of {s}", .{ f.option, f.command }),
            .twice => |option| try w.print("{s} is given twice", .{option}),
            .no_path => |option| try w.print("{s} requires a path", .{option}),
            .no_value => |option| try w.print("{s} requires a value", .{option}),
            .requires => |r| try w.print("{s} requires {s}", .{ r.option, r.required }),
            .expects => |e| {
                try w.print("{s} expects {s}", .{ e.option, e.what });
                if (e.got) |got| try w.print(", got {f}", .{Escaped{ .text = got }});
            },
            .outside => |o| try w.print("{s} must be {s}, got {f}", .{ o.option, o.range, Escaped{ .text = o.got } }),
            .required => |what| try w.print("{s} is required", .{what}),
        }
    }
};

const Row = struct { label: []const u8, help: []const u8 };

const Request = enum { version, help };

pub fn Options(comptime Name: type) type {
    return std.EnumArray(Name, Option);
}

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

        /// Refuses a value outside its range, the range in the shared words: "from 0 to 10".
        pub fn outside(self: *const Self, found: Found, range: []const u8) Refused {
            return self.refuse(.{ .outside = .{ .option = found.spelling, .range = range, .got = found.value } });
        }

        pub fn integer(self: *const Self, comptime T: type, comptime min: T, comptime max: T, found: Found) Refused!T {
            const range = std.fmt.comptimePrint("from {d} to {d}", .{ min, max });
            const n = decimal(T, found.value) orelse return self.outside(found, range);
            return if (n >= min and n <= max) n else self.outside(found, range);
        }

        pub fn number(self: *const Self, found: Found) Refused!f64 {
            return real(found.value) orelse self.expects(found, "a number");
        }

        pub fn word(self: *const Self, comptime E: type, found: Found) Refused!E {
            return dictionary.parse(E, found.value) orelse self.expects(found, comptime dictionary.choices(E));
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
        for (rows) |row| text = text ++ "  " ++ row.label ++ @as([width + 3 - row.label.len]u8, @splat(' ')) ++ row.help ++ "\n";
        return text;
    }
}

pub fn wanted(comptime tool: Tool, comptime Name: type, comptime options: Options(Name), argv: []const []const u8) ?Request {
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
        var text = @tagName(name).*;
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

fn requests(comptime tool: Tool) Options(Request) {
    const v = tool.version;
    return .init(.{
        .version = .{ .short = 'v', .help = std.fmt.comptimePrint("prints {s} {d}.{d}.{d} and exits 0", .{ tool.name, v.major, v.minor, v.patch }) },
        .help = .{ .short = 'h', .help = "prints the usage and exits 0; no argument does the same" },
    });
}
