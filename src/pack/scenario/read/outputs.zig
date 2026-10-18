const std = @import("std");
const core = @import("shared").core;
const System = core.types.System;
const SatId = core.types.SatId;
const SatSet = core.types.SatSet;
const command = @import("shared").bundle.command;
const PowerUnit = command.PowerUnit;
const PowerLevel = command.PowerLevel;
const PowerEntry = command.PowerEntry;
const model = @import("shared").bundle.scenario;
const node = @import("shared").json.node;
const table = @import("shared").json.table;

const min_sample_rate_mhz = 0.001;
const default_cn0_dbhz: f64 = 47;
const grid_warn_tolerance_khz = 1e-6;
const grid_warn_tolerance_hz = 1e-3;
const max_schedule_time_s = 4.0e12;
const Key = table.Key;
const Ctx = node.Ctx;
const Error = node.Error;

pub const least_ms_s = 0.0005;
const output_interval_range: table.Range = .{ .min = least_ms_s, .max = 4.0e6 };
const max_svid = blk: {
    var most: u8 = 0;
    for (System.all) |system| most = @max(most, system.capacity());
    break :blk most;
};
const counts = blk: {
    var text: []const u8 = "";
    for (System.all, 0..) |system, i| text = text ++ (if (i == 0) "" else ", ") ++ std.fmt.comptimePrint("{s} {d}", .{ System.words.get(system), system.capacity() });
    break :blk text;
};

pub const RawSamples = struct {
    format: model.IqFormat = undefined,
    sample_freq: f64 = undefined,
    center_freq: f64 = undefined,

    pub const table = [_]Key{
        .{ .name = "format", .required = true, .what = "sample format", .doc = "the sample format: IQ2, IQ4, IQ8 or IQ16" },
        .{ .name = "sampleFreq", .required = true, .range = .{ .min = min_sample_rate_mhz, .max = @as(f64, @floatFromInt(model.Samples.max_rate_hz)) / 1e6 }, .unit = "MHz", .doc = "the sample rate, kept on the 1 kHz grid" },
        .{ .name = "centerFreq", .required = true, .range = .{ .min = 0, .open_min = true, .max = @as(f64, @floatFromInt(model.Samples.max_center_hz)) / 1e6 }, .unit = "MHz", .doc = "the centre frequency, kept on whole hertz" },
    };
};

const interval_key: Key = .{ .name = "interval", .range = output_interval_range, .unit = "s", .default = .{ .number = 1 }, .doc = "the time between epochs, stored in whole milliseconds" };

pub const RawObservation = struct {
    interval: f64 = undefined,

    pub const table = [_]Key{interval_key};
};

pub const RawPosition = struct {
    interval: f64 = undefined,
    format: model.PositionFormat = undefined,

    pub const table = [_]Key{ interval_key, .{ .name = "format", .required = true, .what = "position format", .doc = "the file's format: ECEF, LLA or KML" } };
};

pub const RawMask = struct {
    system: System = undefined,
    svid: ?[]const u32 = null,

    pub const table = [_]Key{
        .{ .name = "system", .required = true, .doc = "the system: GPS, BDS, Galileo or GLONASS" },
        .{ .name = "svid", .one_or_many = true, .range = .{ .min = 1, .max = max_svid }, .doc = "the satellites masked out, 1 to the system's count (" ++ counts ++ "); absent: none" },
    };
};

fn satellites(system: System, svids: []const u32, ctx: *const Ctx, path: []const u8) Error!?[]const SatId {
    const out = try ctx.arena.alloc(SatId, svids.len);
    var ok = true;
    for (svids, 0..) |svid, i| {
        out[i] = SatId.fromPrn(system, svid) catch {
            try ctx.diags.err(.out_of_range, try node.element(ctx, path, i), "a {s} svid must be from 1 to {d}, got {d}", .{ system.displayName(), system.capacity(), svid });
            ok = false;
            continue;
        };
    }
    return if (ok) out else null;
}

pub fn resolveSamples(raw: RawSamples, ctx: *const Ctx, path: []const u8) Error!model.Samples {
    const mhz = raw.sample_freq;
    const khz_f = @round(mhz * 1000.0);
    // A value on its grid is whole kilohertz or hertz, so written with every digit, as an integer is.
    if (@abs(khz_f - mhz * 1000.0) > grid_warn_tolerance_khz) {
        const moved = khz_f / 1000.0;
        try ctx.diags.warn(.sample_rate_rounded, try node.join(ctx, path, "sampleFreq"), "sample rate moved onto the kHz grid: {f} MHz -> {d} MHz", .{ node.Number{ .value = mhz, .apart = moved }, moved });
    }
    const center_mhz = raw.center_freq;
    const center_hz = @round(center_mhz * 1e6);
    if (@abs(center_hz - center_mhz * 1e6) > grid_warn_tolerance_hz) {
        const moved = center_hz / 1e6;
        try ctx.diags.warn(.center_rounded, try node.join(ctx, path, "centerFreq"), "centre frequency moved onto whole hertz: {f} MHz -> {d} MHz", .{ node.Number{ .value = center_mhz, .apart = moved }, moved });
    }
    return .{
        .format = raw.format,
        .sample_rate = model.SampleRate.fromKhz(@intFromFloat(khz_f)),
        .center = .{ .hz = @intFromFloat(center_hz) },
    };
}

fn intervalMs(seconds: f64) u32 {
    return @intFromFloat(@round(seconds * 1000.0));
}

pub fn resolveObservation(raw: RawObservation) model.Observation {
    return .{ .interval_ms = intervalMs(raw.interval) };
}

pub fn resolvePosition(raw: RawPosition) model.Position {
    return .{ .interval_ms = intervalMs(raw.interval), .format = raw.format };
}

pub fn resolveMaskOut(entries: []const RawMask, ctx: *const Ctx, path: []const u8) Error!?std.EnumArray(System, SatSet) {
    var ok = true;
    var mask_out = std.EnumArray(System, SatSet).initFill(.empty);
    for (entries, 0..) |entry, i| {
        const system = entry.system;
        const sats = try satellites(system, entry.svid orelse &.{}, ctx, try node.join(ctx, try node.element(ctx, path, i), "svid")) orelse {
            ok = false;
            continue;
        };
        for (sats) |sat| mask_out.getPtr(system).insert(sat);
    }
    return if (ok) mask_out else null;
}

pub const RawPower = struct {
    noise_floor: f64 = undefined,
    init_power: RawInitPower = undefined,
    elevation_adjust: bool = undefined,
    signal_power: ?[]const RawSignalPower = null,

    pub const table = [_]Key{
        .{ .name = "noiseFloor", .range = .{ .min = command.noise_floor_range[0], .max = command.noise_floor_range[1] }, .unit = noise_floor_unit, .default = .{ .number = -172 }, .doc = "the noise density N0 of the samples" },
        .{ .name = "initPower", .default = .{ .fields = &.{ .{ .name = "unit", .value = .{ .word = "dBHz" } }, .{ .name = "value", .value = .{ .number = default_cn0_dbhz } } } }, .doc = "the C/N0 of every satellite without a scheduled value" },
        .{ .name = "elevationAdjust", .default = .{ .boolean = false }, .doc = "fades every satellite at its default power by 25 (1 - sqrt(sin elevation)) dB" },
        .{ .name = "signalPower", .one_or_many = true, .doc = "a schedule of power levels, each applied at its time; absent: none" },
    };
};

const noise_floor_unit = "dBm/Hz";

const RawInitPower = struct {
    unit: PowerUnit = undefined,
    value: f64 = undefined,

    pub const table = [_]Key{
        .{ .name = "unit", .what = "power unit", .default = .{ .word = "dBHz" }, .doc = "the unit of value: dBHz, the C/N0; dBm and dBW, a power over the noise floor" },
        .{ .name = "value", .required = true, .unit_key = "unit", .doc = "the level in unit" },
    };
};

const RawSignalPower = struct {
    system: System = undefined,
    svid: ?[]const u32 = null,
    power_value: ?[]const RawPowerValue = null,

    pub const table = [_]Key{
        .{ .name = "system", .required = true, .doc = "the system: GPS, BDS, Galileo or GLONASS" },
        .{ .name = "svid", .one_or_many = true, .range = .{ .min = 0, .max = max_svid }, .doc = "the satellites, 1 to the system's count; 0, [0] or absent: every satellite of the system" },
        .{ .name = "powerValue", .one_or_many = true, .doc = "the levels and their times; absent: the entry sets nothing" },
    };
};

const RawPowerValue = struct {
    unit: PowerUnit = undefined,
    value: ?f64 = null,
    time: f64 = undefined,

    pub const table = [_]Key{
        .{ .name = "unit", .what = "power unit", .default = .{ .word = "dBHz" }, .doc = "the unit of value: dBHz, the C/N0; dBm and dBW, a power over the noise floor in force" },
        .{ .name = "value", .unit_key = "unit", .doc = "the level in unit; absent: back to the default C/N0 and the fade" },
        .{ .name = "time", .range = .{ .min = 0, .max = max_schedule_time_s }, .unit = "s", .default = .{ .number = 0 }, .doc = "when the level applies, from the run start, on the millisecond grid" },
    };
};

fn powerEntry(system: System, sat: ?SatId, level: ?PowerLevel, at_ms: u64) PowerEntry {
    return .{ .at_epoch = at_ms, .target = if (sat) |one| .{ .sat = one } else .{ .whole = system }, .level = level };
}

pub fn resolvePower(raw: RawPower, ctx: *const Ctx, path: []const u8) Error!?model.Power {
    var ok = true;
    const noise_floor = raw.noise_floor;
    const init_cn0 = (PowerLevel{ .unit = raw.init_power.unit, .value = raw.init_power.value }).cn0(noise_floor);
    try requireInRange(ctx, try node.join(ctx, path, "initPower"), "C/N0", init_cn0, command.cn0_range, "dB-Hz", &ok);

    var schedule: std.ArrayList(PowerEntry) = .empty;
    const list_path = try node.join(ctx, path, "signalPower");
    var entries: usize = 0;
    for (raw.signal_power orelse &.{}, 0..) |entry, i| {
        const system = entry.system;
        const entry_path = try node.element(ctx, list_path, i);
        const svids = entry.svid orelse &.{};
        const all_satellites = svids.len == 1 and svids[0] == 0;
        const sats: []const SatId = if (all_satellites) &.{} else targets: {
            const svid_path = try node.join(ctx, entry_path, "svid");
            break :targets try satellites(system, svids, ctx, svid_path) orelse {
                ok = false;
                continue;
            };
        };

        const values = entry.power_value orelse &.{};
        entries += @max(sats.len, 1) * values.len;
        if (entries > model.max_power_entries) {
            try ctx.diags.err(.out_of_range, list_path, "the schedule expands to more than {d} entries of one satellite and one value", .{model.max_power_entries});
            ok = false;
            break;
        }

        for (values, 0..) |pv, j| {
            const level: ?PowerLevel = if (pv.value) |v| .{ .unit = pv.unit, .value = v } else null;
            if (level) |value| {
                const values_path = try node.join(ctx, entry_path, "powerValue");
                const value_path = try node.element(ctx, values_path, j);
                const cn0_dbhz = value.cn0(noise_floor);
                try requireInRange(ctx, value_path, "C/N0", cn0_dbhz, command.cn0_range, "dB-Hz", &ok);
            }

            const at_ms: u64 = @intFromFloat(@round(pv.time * 1000.0));
            if (sats.len == 0) {
                try schedule.append(ctx.arena, powerEntry(system, null, level, at_ms));
            } else for (sats) |sat| {
                try schedule.append(ctx.arena, powerEntry(system, sat, level, at_ms));
            }
        }
    }
    if (!ok) return null;

    std.mem.sort(PowerEntry, schedule.items, {}, struct {
        fn lessThan(_: void, a: PowerEntry, b: PowerEntry) bool {
            return a.at_epoch < b.at_epoch;
        }
    }.lessThan);
    return .{ .noise_floor_dbm_hz = noise_floor, .init_cn0_dbhz = init_cn0, .elevation_fade = raw.elevation_adjust, .schedule = schedule.items };
}

fn requireInRange(ctx: *const Ctx, path: []const u8, what: []const u8, v: f64, range: [2]f64, unit: []const u8, ok: *bool) Error!void {
    if (v >= range[0] and v <= range[1]) return;
    const allowed: table.Range = .{ .min = range[0], .max = range[1] };
    try ctx.diags.err(.out_of_range, path, "{s} must be {f} {s}, got {f}", .{ what, allowed, unit, node.Number{ .value = v, .outside = allowed } });
    ok.* = false;
}
