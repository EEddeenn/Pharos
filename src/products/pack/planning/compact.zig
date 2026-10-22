const std = @import("std");
const records = @import("domain/navigation/records");
const precise = @import("domain/navigation/precise/product");
const gnss_types = @import("domain/gnss_types");
const stored = @import("phb/model/plan");
const GpsTime = @import("domain/time/gps").GpsTime;
const Choices = stored.PlanChoices;
const Leg = stored.Leg;

pub const Result = struct { ephemerides: records.Ephemerides, choices: Choices };
const product_trim_slack_samples = 3;

pub fn compact(arena: std.mem.Allocator, ephemerides: records.Ephemerides, choices: Choices) std.mem.Allocator.Error!Result {
    const used_kepler = try arena.alloc(bool, ephemerides.kepler.len);
    const used_glonass = try arena.alloc(bool, ephemerides.glonass.len);
    @memset(used_kepler, false);
    @memset(used_glonass, false);
    for (choices.timelines) |legs| markUsed(legs, used_kepler, used_glonass);
    const map_kepler = try arena.alloc(u32, ephemerides.kepler.len);
    const kepler = try kept(records.KeplerEphemeris, arena, ephemerides.kepler, used_kepler, map_kepler);
    const map_glonass = try arena.alloc(u32, ephemerides.glonass.len);
    const glonass = try kept(records.GlonassEphemeris, arena, ephemerides.glonass, used_glonass, map_glonass);
    var remapped_choices: Choices = undefined;
    for (choices.timelines, &remapped_choices.timelines) |legs, *result| result.* = try remapped(arena, legs, map_kepler, map_glonass);
    return .{ .ephemerides = .{ .kepler = kepler, .glonass = glonass }, .choices = remapped_choices };
}

pub fn trimPrecise(arena: std.mem.Allocator, data: precise.Data, start: GpsTime, spans_ms: std.EnumArray(gnss_types.System, u64)) std.mem.Allocator.Error!precise.Data {
    const margin_s = @as(f64, @floatFromInt(precise.window / 2 + product_trim_slack_samples)) * data.interval_s + precise.coverage_span_s;
    return data.trimmed(arena, start.addSeconds(-margin_s), start.addMs(@intCast(std.mem.max(u64, &spans_ms.values))).addSeconds(margin_s));
}

fn markUsed(legs_of: []const Leg, used_kepler: []bool, used_glonass: []bool) void {
    for (legs_of) |leg| {
        const binding = leg.binding orelse continue;
        switch (binding.reference) {
            .kepler => |k| used_kepler[k] = true,
            .glonass => |k| used_glonass[k] = true,
        }
        for (std.enums.values(records.NavSource)) |source| if (binding.sources.get(source)) |k| {
            used_kepler[k] = true;
        };
    }
}

fn remapped(arena: std.mem.Allocator, old: []const Leg, map_kepler: []const u32, map_glonass: []const u32) std.mem.Allocator.Error![]const Leg {
    const new = try arena.alloc(Leg, old.len);
    for (new, old) |*n, leg| {
        n.* = leg;
        const binding = if (n.binding) |*binding| binding else continue;
        binding.reference = switch (binding.reference) {
            .kepler => |k| .{ .kepler = map_kepler[k] },
            .glonass => |k| .{ .glonass = map_glonass[k] },
        };
        var sources = binding.sources.iterator();
        while (sources.next()) |source| source.value.* = map_kepler[source.value.*];
    }
    return new;
}

fn kept(comptime T: type, arena: std.mem.Allocator, all: []const T, used: []const bool, map: []u32) std.mem.Allocator.Error![]T {
    const out = try arena.alloc(T, std.mem.countScalar(bool, used, true));
    var n: u32 = 0;
    for (all, used, map) |e, u, *m| if (u) {
        m.* = n;
        out[n] = e;
        n += 1;
    };
    return out;
}
