const std = @import("std");
const json_schema = @import("base/json/schema");
const json_node = @import("base/json/node");
const json_table = @import("base/json/table");
const dictionary = @import("base/text/dictionary");
const gnss_types = @import("domain/gnss_types");
const configuration = @import("simulation/model/config");
const ionosphere_config = @import("simulation/model/ionosphere");
const time = @import("products/pack/input/scenario/time");
const outputs = @import("products/pack/input/scenario/outputs");
const messages = @import("products/pack/input/scenario/messages/read");
const Range = @import("base/math/range").Range;
const System = gnss_types.System;
const Signal = gnss_types.Signal;
const Node = json_node.Node;
const Key = json_table.Key;

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
        .{ .name = "time", .required = true, .doc = "the scenario start, from 2000 through 2099: the time of epoch 0 and of the trajectory's first knot" },
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

    pub fn schemaMetadata(s: *json_schema.Schema) std.Io.Writer.Error!void {
        try s.begin("x-satellite-capacity");
        inline for (System.all) |system| {
            try s.jw.objectField(comptime system.name());
            try s.jw.write(system.capacity());
        }
        try s.end();
        try s.begin("x-ionosphere-coefficients");
        inline for (comptime std.enums.values(ionosphere_config.Model)) |which| {
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

    pub fn fromJson(n: Node) json_node.Error!?SignalWord {
        return .{ .signal = try n.word(Signal, "signal") orelse return null };
    }

    pub fn schema(s: *json_schema.Schema) std.Io.Writer.Error!void {
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

pub const RawPrecise = struct {
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
    refs: configuration.ClockReferences = .{},

    pub fn fromJson(n: Node) json_node.Error!?ClockReference {
        const ctx = n.ctx;
        const o = try n.object() orelse return null;
        var out: ClockReference = .{};
        var ok = true;
        var listed = false;
        for (o.keys(), 0..) |key, i| {
            const entry = try o.entry(i);
            const system = dictionary.parse(System, key) orelse {
                try json_node.unknownKey(ctx, entry.path, if (listed) null else comptime dictionary.words(System));
                listed = true;
                ok = false;
                continue;
            };
            const ref = try entry.word(configuration.ClockRef, "clock reference") orelse {
                ok = false;
                continue;
            };
            if (ref.system() != system) {
                try ctx.diags.err(.unknown_name, entry.path, "{s} is not a {s} clock reference", .{ ref.name(), system.displayName() });
                ok = false;
                continue;
            }
            if (system == .gal) out.refs.galileo = switch (ref) {
                .e1e5a => .e1e5a,
                .e1e5b => .e1e5b,
                else => unreachable,
            };
        }
        return if (ok) out else null;
    }

    pub fn schema(s: *json_schema.Schema) std.Io.Writer.Error!void {
        try s.text("type", "object");
        try s.begin("properties");
        inline for (comptime std.enums.values(System)) |system| {
            const pairs = comptime blk: {
                var words: []const []const u8 = &.{};
                for (std.enums.values(configuration.ClockRef)) |ref| {
                    if (ref.system() == system) words = words ++ [_][]const u8{ref.name()};
                }
                break :blk words;
            };
            const name = comptime System.words.get(system);
            try s.begin(name);
            try s.text("description", "the pair the " ++ name ++ " product clocks refer to");
            try s.text("default", comptime configuration.ClockRef.defaults.get(system).name());
            try s.text("type", "string");
            try s.words("enum", pairs);
            try s.end();
        }
        try s.end();
        try s.jw.objectField("additionalProperties");
        try s.jw.write(false);
    }
};

const service_interval_range: Range = .{ .min = 1, .max = configuration.max_service_interval_s };

pub const RawHas = struct {
    enable: bool = undefined,
    status: configuration.HasStatus = undefined,
    clock_interval: u32 = undefined,
    orbit_interval: u32 = undefined,

    pub const table = [_]Key{
        .{ .name = "enable", .default = .{ .boolean = true }, .doc = "false drops the block, its other keys still checked" },
        .{ .name = "status", .what = "HAS status", .default = .{ .word = "test" }, .doc = "the status of the page header: test or operational" },
        .{ .name = "clockInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 10 }, .doc = "whole seconds between clock messages" },
        .{ .name = "orbitInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 50 }, .doc = "whole seconds between mask, orbit and bias messages" },
    };
};

pub const RawPppB2b = struct {
    enable: bool = undefined,
    clock_interval: u32 = undefined,
    orbit_interval: u32 = undefined,

    pub const table = [_]Key{
        .{ .name = "enable", .default = .{ .boolean = true }, .doc = "false drops the block, its other keys still checked" },
        .{ .name = "clockInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 6 }, .doc = "whole seconds between clock epochs" },
        .{ .name = "orbitInterval", .range = service_interval_range, .unit = "s", .default = .{ .number = 48 }, .doc = "the orbit cycle in whole seconds" },
    };
};

pub const RawIonosphere = struct {
    model: ionosphere_config.Selection = undefined,
    parameters: ?[]const f64 = null,

    pub const table = [_]Key{
        .{ .name = "model", .what = "ionosphere model", .default = .{ .word = "klobuchar" }, .doc = "auto selects by constellation; klobuchar, bdsKlobuchar, nequick, bdgim or none applies to every constellation" },
        .{ .name = "parameters", .doc = "the model's coefficients, which its messages broadcast too; absent: the navigation data's set" },
    };

    pub const kinds: json_table.Kinds(ionosphere_config.Selection) = .{ .key = "model", .of = .init(.{
        .auto = .{ .keys = &.{.{ .name = "parameters", .doc = "auto takes its coefficients from the navigation data and accepts no parameters" }}, .count = 0 },
        .klobuchar = counted(.klobuchar, "the model's coefficients alpha0-3 and beta0-3; absent: the navigation data's set", null),
        .bds_klobuchar = counted(.bds_klobuchar, "the model's coefficients alpha0-3 and beta0-3; absent: the navigation data's set", null),
        .nequick = counted(.nequick, "the model's coefficients ai0-ai2; absent: the navigation data's set", null),
        .bdgim = counted(.bdgim, "the model's coefficients alpha1-9; absent: the navigation data's set", "TECu"),
        .none = counted(.none, "none: the model takes no coefficients", null),
    }) };

    fn counted(comptime which: ionosphere_config.Model, comptime doc: []const u8, comptime unit: ?[]const u8) json_table.Kind {
        const n = which.parameterCount();
        return .{ .keys = &.{.{ .name = "parameters", .items = .{ .min = n, .max = n }, .unit = unit, .doc = doc }} };
    }
};
