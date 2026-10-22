const std = @import("std");
const diagnostics = @import("base/diagnostics");
const json_node = @import("base/json/node");
const json_table = @import("base/json/table");
const angles = @import("base/math/angles");
const gnss_types = @import("domain/gnss_types");
const names = @import("phb/model/names");
const configuration = @import("simulation/model/config");
const ionosphere_config = @import("simulation/model/ionosphere");
const publications = @import("simulation/model/publications");
const request = @import("products/pack/input/scenario/request");
const schema = @import("products/pack/input/scenario/schema");
const time = @import("products/pack/input/scenario/time");
const outputs = @import("products/pack/input/scenario/outputs");
const messages = @import("products/pack/input/scenario/messages/read");
const admission = @import("products/pack/input/admission/scenario");
const Number = @import("base/text/number").Number;
const Signal = gnss_types.Signal;
const Diagnostics = diagnostics.Diagnostics;
const Ctx = json_node.Ctx;

pub fn readRequest(arena: std.mem.Allocator, text: []const u8, diags: *Diagnostics) diagnostics.InputError!request.Request {
    const ctx: Ctx = .{ .arena = arena, .diags = diags };
    const tree = try json_node.parseTree(&ctx, text) orelse return error.InvalidInput;
    const accepted = try interpret(&ctx, tree) orelse return error.InvalidInput;
    try admission.admit(&accepted, diags);
    if (diags.hasErrors()) return error.InvalidInput;
    return accepted;
}

fn interpret(ctx: *const Ctx, tree: std.json.Value) json_node.Error!?request.Request {
    const obj = try json_node.root(ctx, tree).object() orelse return null;
    const raw = try json_table.read(schema.Raw, obj) orelse return null;
    const start = try time.resolve(raw.time, ctx, "time");
    const mask_out = try outputs.resolveMaskOut(raw.mask_out orelse &.{}, ctx, "maskOut");
    const samples: ?configuration.Samples = if (raw.samples) |x| try outputs.resolveSamples(x, ctx, "samples") else null;
    const power = try outputs.resolvePower(raw.power orelse comptime json_table.defaults(outputs.RawPower), ctx, "power");

    const ephemeris = raw.ephemeris orelse &.{};
    const almanac = raw.almanac orelse &.{};
    const nav_files = try ctx.arena.alloc(names.NavFile, ephemeris.len + almanac.len);
    for (nav_files[0..ephemeris.len], ephemeris) |*n, f| n.* = .{ .path = f.name, .kind = .ephemeris };
    for (nav_files[ephemeris.len..], almanac) |*n, f| n.* = .{ .path = f.name, .kind = .almanac };

    var signals = std.EnumSet(Signal).empty;
    for (raw.signals orelse &.{}, 0..) |word, i| {
        const signal = word.signal;
        if (signals.contains(signal)) try ctx.diags.warn(.duplicate, try json_node.element(ctx, "signals", i), "{s} is listed twice", .{signal.name()});
        signals.insert(signal);
    }

    const precise = if (raw.precise) |p| resolvePrecise(p) else null;
    const ionosphere = try resolveIonosphere(raw.ionosphere orelse comptime json_table.defaults(schema.RawIonosphere), ctx, "ionosphere");
    const declarations: ?publications.Publications = if (raw.messages) |m| try messages.resolve(m, ctx, "messages") else .{};
    const resolved_ionosphere = ionosphere orelse return null;

    return .{
        .name = raw.name,
        .start = start orelse return null,
        .trajectory_file = raw.trajectory,
        .duration_ms = if (raw.duration) |d| @intFromFloat(@round(d * 1000.0)) else null,
        .nav_files = nav_files,
        .antenna = raw.antenna,
        .signals = signals,
        .elevation_mask_rad = angles.deg2rad(raw.elevation_mask),
        .mask_out = mask_out orelse return null,
        .samples = samples,
        .observation = if (raw.observation) |x| outputs.resolveObservation(x) else null,
        .position = if (raw.position) |x| outputs.resolvePosition(x) else null,
        .power = power orelse return null,
        .precise = precise,
        .has = if (raw.has) |h| resolveHas(h) else null,
        .ppp_b2b = if (raw.ppp_b2b) |p| resolvePppB2b(p) else null,
        .ionosphere = resolved_ionosphere,
        .messages = declarations orelse return null,
    };
}

fn resolvePrecise(raw: schema.RawPrecise) request.Precise {
    return .{
        .orbit = raw.orbit,
        .clock = raw.clock orelse &.{},
        .clock_reference = if (raw.clock_reference) |c| c.refs else .{},
    };
}

fn resolveHas(raw: schema.RawHas) ?configuration.Has {
    if (!raw.enable) return null;
    return .{ .status = raw.status, .clock_interval_s = raw.clock_interval, .orbit_interval_s = raw.orbit_interval };
}

fn resolvePppB2b(raw: schema.RawPppB2b) ?configuration.PppB2b {
    if (!raw.enable) return null;
    return .{ .clock_interval_s = raw.clock_interval, .orbit_interval_s = raw.orbit_interval };
}

fn resolveIonosphere(raw: schema.RawIonosphere, ctx: *const Ctx, path: []const u8) json_node.Error!?request.Ionosphere {
    const selected = try json_table.kind(schema.RawIonosphere, raw, ctx, path) orelse return null;
    switch (selected) {
        .auto => return .auto,
        inline else => |active, tag| {
            const which: ionosphere_config.Model = comptime @field(ionosphere_config.Model, @tagName(tag));
            const count = comptime which.parameterCount();
            const given = active.parameters orelse return without(which);
            const values = given[0..count].*;
            const list_path = try json_node.join(ctx, path, "parameters");
            var ok = true;
            for (values, 0..) |v, i| {
                var one: [count]f64 = @splat(0);
                one[i] = v;
                if (coefficients(which, one).misfit()) |name| {
                    try ctx.diags.err(.out_of_range, try json_node.element(ctx, list_path, i), "{s} = {f} does not fit the field its messages broadcast it in", .{ name, Number{ .value = v } });
                    ok = false;
                }
            }
            if (!ok) return null;
            return coefficients(which, values);
        },
    }
}

fn without(which: ionosphere_config.Model) request.Ionosphere {
    return switch (which) {
        inline .klobuchar, .bds_klobuchar, .nequick, .bdgim => |tag| @unionInit(request.Ionosphere, @tagName(tag), null),
        .none => .none,
    };
}

fn coefficients(comptime which: ionosphere_config.Model, values: [which.parameterCount()]f64) request.Ionosphere {
    return switch (which) {
        .klobuchar => .{ .klobuchar = .{ .alpha = values[0..4].*, .beta = values[4..8].* } },
        .bds_klobuchar => .{ .bds_klobuchar = .{ .alpha = values[0..4].*, .beta = values[4..8].* } },
        .nequick => .{ .nequick = .fromArray(values) },
        .bdgim => .{ .bdgim = values },
        .none => .none,
    };
}
