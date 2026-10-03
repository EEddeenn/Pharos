const std = @import("std");
const core = @import("shared").core;
const dictionary = core.dictionary;
const constants = core.constants;
const System = core.types.System;
const Signal = core.types.Signal;
const model = @import("shared").bundle.scenario;
const request = @import("request.zig");
const Diagnostics = @import("shared").core.diagnostics.Diagnostics;
const json = @import("shared").json;
const node = json.node;
const table = json.table;
const Key = table.Key;
const Node = node.Node;
const Ctx = node.Ctx;
const time = @import("read/time.zig");
const outputs = @import("read/outputs.zig");
const messages = @import("read/messages.zig");

const Error = core.diagnostics.InputError;

pub fn parse(arena: std.mem.Allocator, text: []const u8, diags: *Diagnostics) Error!request.Request {
    const ctx: node.Ctx = .{ .arena = arena, .diags = diags };
    const tree = try node.parseTree(&ctx, text) orelse return error.InvalidInput;
    return try interpret(&ctx, tree) orelse error.InvalidInput;
}

pub const Raw = struct {
    version: ?Node = null,
    description: ?Node = null,
    name: []const u8 = undefined,
    time: time.Raw = undefined,
    trajectory: []const u8 = undefined,
    duration: ?f64 = null,
    ephemeris: ?[]const RawNavFile = null,
    almanac: ?[]const RawNavFile = null,
    antenna: ?[]const u8 = null,
    signals: ?[]const SignalWord = null,
    elevation_mask: f64 = undefined,
    mask_out: ?[]const outputs.RawMask = null,
    samples: ?outputs.RawSamples = null,
    observation: ?outputs.RawObservation = null,
    position: ?outputs.RawPosition = null,
    power: ?outputs.RawPower = null,
    precise: ?RawPrecise = null,
    has: ?RawHas = null,
    ppp_b2b: ?RawPppB2b = null,
    ionosphere: ?RawIonosphere = null,
    messages: ?messages.Raw = null,

    pub const table = [_]Key{
        .{ .name = "version", .doc = "informational, any JSON value" },
        .{ .name = "description", .doc = "informational, any JSON value" },
        .{ .name = "name", .default = .{ .text = "" }, .doc = "informational; carried into the run manifest" },
        .{ .name = "time", .required = true, .doc = "the scenario start: the time of epoch 0 and of the trajectory's first knot" },
        .{ .name = "trajectory", .required = true, .doc = "the receiver's .pht file, relative to the scenario's directory" },
        .{ .name = "duration", .range = .{ .min = outputs.least_ms_s, .max = 1e7 }, .unit = "s", .doc = "the run's length, run as whole milliseconds; absent: the whole trajectory" },
        .{ .name = "ephemeris", .one_or_many = true, .doc = "RINEX 3 or 4 navigation files, in order; absent: none" },
        .{ .name = "almanac", .one_or_many = true, .doc = "almanac files, in order; absent: none" },
        .{ .name = "antenna", .doc = "an ANTEX file giving each signal its satellite's phase centre and yaw law; absent: signals leave from the orbit's point" },
        .{ .name = "signals", .one_or_many = true, .doc = "the signals transmitted; absent: none" },
        .{ .name = "elevationMask", .range = .{ .min = -90, .max = 90 }, .unit = "deg", .default = .{ .number = 5 }, .doc = "the elevation below which a satellite gets no channel and no observation line" },
        .{ .name = "maskOut", .one_or_many = true, .doc = "satellites never transmitted, whatever their elevation; absent: none" },
        .{ .name = "samples", .doc = "the IF stream of pharos-run; absent: none" },
        .{ .name = "observation", .doc = "the RINEX observation file of pharos-obs; absent: none" },
        .{ .name = "position", .doc = "the position file of pharos-obs; absent: none" },
        .{ .name = "power", .doc = "the noise floor and the C/N0; absent: every key at its default" },
        .{ .name = "precise", .doc = "a precise orbit and clock product flown in place of the broadcast orbits and clocks; absent: none" },
        .{ .name = "has", .doc = "Galileo HAS message type 1 on the E6 C/NAV pages; absent: the dummy page" },
        .{ .name = "pppB2b", .doc = "the PPP-B2b corrections on the B2b of the BDS-3 GEO satellites; absent: the null message" },
        .{ .name = "ionosphere", .doc = "the model of the ionospheric delays; absent: every key at its default" },
        .{ .name = "messages", .doc = "content only a provider declares: GPS, Galileo I/NAV and BDS D2 publications; absent: none" },
    };

    pub fn schemaMetadata(s: *json.schema.Schema) std.Io.Writer.Error!void {
        try s.begin("x-satellite-capacity");
        inline for (System.all) |system| {
            try s.jw.objectField(comptime system.name());
            try s.jw.write(system.capacity());
        }
        try s.end();
        try s.begin("x-ionosphere-coefficients");
        inline for (comptime std.enums.values(model.IonoModel)) |which| {
            try s.jw.objectField(comptime which.name());
            try s.jw.beginArray();
            inline for (0..comptime which.parameterCount()) |index| {
                const name = comptime switch (which) {
                    .klobuchar, .bds_klobuchar => std.fmt.comptimePrint("{s}{d}", .{ if (index < 4) "alpha" else "beta", index % 4 }),
                    .nequick => std.fmt.comptimePrint("ai{d}", .{index}),
                    .bdgim => std.fmt.comptimePrint("alpha{d}", .{index + 1}),
                    .none => unreachable,
                };
                try s.jw.beginObject();
                try s.text("name", name);
                if (which == .bdgim) try s.text("unit", "TECu");
                try s.jw.endObject();
            }
            try s.jw.endArray();
        }
        try s.end();
    }
};

const SignalWord = struct {
    signal: Signal,

    pub fn fromJson(n: Node) node.Error!?SignalWord {
        return .{ .signal = try n.word(Signal, "signal") orelse return null };
    }

    pub fn schema(s: *json.schema.Schema) std.Io.Writer.Error!void {
        try s.text("type", "string");
        try s.words("enum", &Signal.words.values);
        try s.begin("x-system");
        inline for (comptime std.enums.values(Signal)) |signal| try s.text(comptime Signal.words.get(signal), comptime System.words.get(signal.system()));
        try s.end();
    }
};

const RawNavFile = struct {
    name: []const u8 = undefined,

    pub const table = [_]Key{.{ .name = "name", .required = true, .doc = "the file's path, relative to the scenario's directory" }};
};

const RawPrecise = struct {
    orbit: []const []const u8 = undefined,
    clock: ?[]const []const u8 = null,
    clock_reference: ?ClockReference = null,

    pub const table = [_]Key{
        .{ .name = "orbit", .required = true, .one_or_many = true, .items = .{ .min = 1 }, .doc = "SP3 files, merged in order" },
        .{ .name = "clock", .one_or_many = true, .doc = "RINEX clock files, merged in order; absent: the SP3 clocks" },
        .{ .name = "clockReference", .doc = "the pair of signals each system's product clocks refer to, by system" },
    };
};

const ClockReference = struct {
    refs: std.EnumArray(System, model.ClockRef) = model.ClockRef.defaults,

    pub fn fromJson(n: Node) node.Error!?ClockReference {
        const ctx = n.ctx;
        const o = try n.object() orelse return null;
        var out: ClockReference = .{};
        var ok = true;
        for (o.keys(), 0..) |key, i| {
            const entry = try o.entry(i);
            const system = dictionary.parse(System, key) orelse {
                try ctx.diags.warn(.unknown_key, entry.path, "unknown system, ignored", .{});
                continue;
            };
            const ref = try entry.word(model.ClockRef, "clock reference") orelse {
                ok = false;
                continue;
            };
            if (ref.system() != system) {
                try ctx.diags.err(.unknown_name, entry.path, "{s} is not a {s} clock reference", .{ ref.name(), system.displayName() });
                ok = false;
                continue;
            }
            out.refs.set(system, ref);
        }
        try o.finish();
        return if (ok) out else null;
    }

    pub fn schema(s: *json.schema.Schema) std.Io.Writer.Error!void {
        try s.text("type", "object");
        try s.begin("properties");
        inline for (comptime std.enums.values(System)) |system| {
            const pairs = comptime blk: {
                var words: []const []const u8 = &.{};
                for (std.enums.values(model.ClockRef)) |ref| {
                    if (ref.system() == system) words = words ++ [_][]const u8{ref.name()};
                }
                break :blk words;
            };
            const name = comptime System.words.get(system);
            try s.begin(name);
            try s.text("description", "the pair the " ++ name ++ " product clocks refer to");
            try s.text("default", comptime model.ClockRef.defaults.get(system).name());
            try s.text("type", "string");
            try s.words("enum", pairs);
            try s.end();
        }
        try s.end();
    }
};

const service_interval_range: table.Range = .{ .min = 1, .max = model.max_service_interval_s };

const RawHas = struct {
    enable: bool = undefined,
    status: model.HasStatus = undefined,
    clock_interval: u32 = undefined,
    orbit_interval: u32 = undefined,

    pub const table = [_]Key{
        .{ .name = "enable", .default = .{ .boolean = true }, .doc = "false drops the block, its other keys still checked" },
        .{ .name = "status", .what = "HAS status", .default = .{ .word = "test" }, .doc = "the status of the page header: test or operational" },
        .{ .name = "clockInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 10 }, .doc = "whole seconds between clock messages" },
        .{ .name = "orbitInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 50 }, .doc = "whole seconds between mask, orbit and bias messages" },
    };
};

const RawPppB2b = struct {
    enable: bool = undefined,
    clock_interval: u32 = undefined,
    orbit_interval: u32 = undefined,

    pub const table = [_]Key{
        .{ .name = "enable", .default = .{ .boolean = true }, .doc = "false drops the block, its other keys still checked" },
        .{ .name = "clockInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 6 }, .doc = "whole seconds between clock epochs" },
        .{ .name = "orbitInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 48 }, .doc = "the orbit cycle in whole seconds" },
    };
};

const RawIonosphere = struct {
    model: model.IonoSelection = undefined,
    parameters: ?[]const f64 = null,

    pub const table = [_]Key{
        .{ .name = "model", .what = "ionosphere model", .default = .{ .word = "klobuchar" }, .doc = "auto selects by constellation; klobuchar, bdsKlobuchar, nequick, bdgim or none applies to every constellation" },
        .{ .name = "parameters", .doc = "the model's coefficients, which its messages broadcast too; absent: the navigation data's set" },
    };

    pub const kinds: json.table.Kinds(model.IonoSelection) = .{ .key = "model", .of = .init(.{
        .auto = .{ .keys = &.{.{ .name = "parameters", .doc = "auto takes its coefficients from the navigation data and accepts no parameters" }}, .count = 0 },
        .klobuchar = counted(.klobuchar, "the model's coefficients alpha0-3 and beta0-3; absent: the navigation data's set", null),
        .bds_klobuchar = counted(.bds_klobuchar, "the model's coefficients alpha0-3 and beta0-3; absent: the navigation data's set", null),
        .nequick = counted(.nequick, "the model's coefficients ai0-ai2; absent: the navigation data's set", null),
        .bdgim = counted(.bdgim, "the model's coefficients alpha1-9; absent: the navigation data's set", "TECu"),
        .none = counted(.none, "none: the model takes no coefficients", null),
    }) };

    fn counted(comptime which: model.IonoModel, comptime doc: []const u8, comptime unit: ?[]const u8) json.table.Kind {
        const n = which.parameterCount();
        return .{ .keys = &.{.{ .name = "parameters", .items = .{ .min = n, .max = n }, .unit = unit, .doc = doc }} };
    }
};

fn interpret(ctx: *const Ctx, tree: std.json.Value) node.Error!?request.Request {
    const obj = try node.root(ctx, tree).object() orelse return null;
    const raw = try table.read(Raw, obj) orelse return null;
    const start = try time.resolve(raw.time, ctx, "time");
    const mask_out = try outputs.resolveMaskOut(raw.mask_out orelse &.{}, ctx, "maskOut");
    const samples: ?model.Samples = if (raw.samples) |x| try outputs.resolveSamples(x, ctx, "samples") else null;
    const power = try outputs.resolvePower(raw.power orelse comptime table.defaults(outputs.RawPower), ctx, "power");

    const ephemeris = raw.ephemeris orelse &.{};
    const almanac = raw.almanac orelse &.{};
    const nav_files = try ctx.arena.alloc(model.NavFile, ephemeris.len + almanac.len);
    for (nav_files[0..ephemeris.len], ephemeris) |*n, f| n.* = .{ .path = f.name, .kind = .ephemeris };
    for (nav_files[ephemeris.len..], almanac) |*n, f| n.* = .{ .path = f.name, .kind = .almanac };

    var signals = std.EnumSet(Signal).empty;
    for (raw.signals orelse &.{}, 0..) |word, i| {
        const signal = word.signal;
        if (signals.contains(signal)) try ctx.diags.warn(.duplicate, try node.element(ctx, "signals", i), "{s} is listed twice", .{signal.name()});
        signals.insert(signal);
    }

    const precise = if (raw.precise) |p| resolvePrecise(p) else null;
    const ionosphere = try resolveIonosphere(raw.ionosphere orelse comptime table.defaults(RawIonosphere), ctx, "ionosphere");
    const publications: ?model.Messages = if (raw.messages) |m| try messages.resolve(m, ctx, "messages") else .{};
    const resolved_ionosphere = ionosphere orelse return null;

    return .{
        .name = raw.name,
        .start = start orelse return null,
        .trajectory_file = raw.trajectory,
        .duration_ms = if (raw.duration) |d| @intFromFloat(@round(d * 1000.0)) else null,
        .nav_files = nav_files,
        .antenna = raw.antenna,
        .signals = signals,
        .elevation_mask_rad = constants.deg2rad(raw.elevation_mask),
        .mask_out = mask_out orelse return null,
        .samples = samples,
        .observation = if (raw.observation) |x| outputs.resolveObservation(x) else null,
        .position = if (raw.position) |x| outputs.resolvePosition(x) else null,
        .power = power orelse return null,
        .precise = precise,
        .has = if (raw.has) |h| resolveHas(h) else null,
        .ppp_b2b = if (raw.ppp_b2b) |p| resolvePppB2b(p) else null,
        .ionosphere = resolved_ionosphere,
        .messages = publications orelse return null,
    };
}

fn resolvePrecise(raw: RawPrecise) model.Precise {
    return .{
        .orbit = raw.orbit,
        .clock = raw.clock orelse &.{},
        .clock_reference = if (raw.clock_reference) |c| c.refs else model.ClockRef.defaults,
    };
}

fn resolveHas(raw: RawHas) ?model.Has {
    if (!raw.enable) return null;
    return .{ .status = raw.status, .clock_interval_s = raw.clock_interval, .orbit_interval_s = raw.orbit_interval };
}

fn resolvePppB2b(raw: RawPppB2b) ?model.PppB2b {
    if (!raw.enable) return null;
    return .{ .clock_interval_s = raw.clock_interval, .orbit_interval_s = raw.orbit_interval };
}

fn resolveIonosphere(raw: RawIonosphere, ctx: *const Ctx, path: []const u8) node.Error!?request.Ionosphere {
    const selected = try table.kind(RawIonosphere, raw, ctx, path) orelse return null;
    const which: model.IonoSelection = selected;
    const values = switch (selected) {
        inline else => |active| active.parameters orelse return without(which),
    };
    const list_path = try node.join(ctx, path, "parameters");
    var ok = true;
    for (values, 0..) |v, i| {
        var one: [9]f64 = @splat(0);
        one[i] = v;
        if (coefficients(which, one[0..values.len]).misfit()) |name| {
            try ctx.diags.err(.out_of_range, try node.element(ctx, list_path, i), "{s} = {e} does not fit the field its messages broadcast it in", .{ name, v });
            ok = false;
        }
    }
    if (!ok) return null;
    return coefficients(which, values);
}

fn without(which: model.IonoSelection) request.Ionosphere {
    return switch (which) {
        .auto => .auto,
        inline .klobuchar, .bds_klobuchar, .nequick, .bdgim => |tag| @unionInit(request.Ionosphere, @tagName(tag), null),
        .none => .none,
    };
}

fn coefficients(which: model.IonoSelection, values: []const f64) request.Ionosphere {
    return switch (which) {
        .auto => unreachable,
        .klobuchar => .{ .klobuchar = .{ .alpha = values[0..4].*, .beta = values[4..8].* } },
        .bds_klobuchar => .{ .bds_klobuchar = .{ .alpha = values[0..4].*, .beta = values[4..8].* } },
        .nequick => .{ .nequick = .fromArray(values[0..3].*) },
        .bdgim => .{ .bdgim = values[0..9].* },
        .none => .none,
    };
}
