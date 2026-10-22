const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const records = @import("domain/navigation/records");
const navigation_reference = @import("domain/navigation/reference");
const signal_payload = @import("domain/signals/payload");
const message_content = @import("domain/messages/content");
const lnav = @import("domain/messages/gps/lnav/content");
const cnvx = @import("domain/messages/gps/cnav_common/content");
const inav = @import("domain/messages/galileo/inav/content");
const fnav = @import("domain/messages/galileo/fnav/content");
const d1d2 = @import("domain/messages/bds/d1d2/content");
const bcnav = @import("domain/messages/bds/bcnav/content");
const gnav = @import("domain/messages/glonass/gnav/content");
const configuration = @import("simulation/model/config");
const selection = @import("simulation/model/signals");
const flight_plan = @import("simulation/model/flight_plan");
const message_policy = @import("simulation/model/message_policy");
const stored = @import("phb/model/plan");
const select = @import("products/pack/planning/select");
const resolve = @import("products/pack/planning/resolve");
const time_grid = @import("products/pack/planning/time_grid");
const d1d2_fit = @import("products/pack/planning/fit/d1d2");
const GpsTime = @import("domain/time/gps").GpsTime;
const ServicePlan = @import("simulation/model/services").ServicePlan;
const Ephemerides = records.Ephemerides;
const Leg = stored.Leg;
const Binding = stored.Binding;
const Content = message_content.Content;
const Choice = message_content.Choice;

pub const Planned = struct { choices: stored.PlanChoices, contents: flight_plan.PreparedContents };

const PreparedLegs = struct { choices: []const Leg, contents: []const []const Content };

const PreparedBinding = struct { choices: []const Choice, contents: []const Content };

pub fn build(arena: std.mem.Allocator, config: *const configuration.Config, ephemerides: *const Ephemerides, services: ServicePlan, leap: civil.Leap) std.mem.Allocator.Error!Planned {
    const spans_ms = flight_plan.spansMs(config.signals, services, config.duration_ms);
    var result: Planned = .{ .choices = .{ .timelines = @splat(&.{}) }, .contents = @splat(&.{}) };
    const payload = signal_payload.at(config.start);
    const needed = message_policy.needed(config.signals, services, &payload);
    var enabled = selection.systems(config.signals).iterator();
    while (enabled.next()) |system| {
        const span_ms = spans_ms.get(system);
        const times = try time_grid.samples(arena, config.start, span_ms, system, leap);
        var sats = system.satellites();
        while (sats.next()) |sat| {
            const signals = config.signals.intersectWith(payload.transmitted(sat));
            const chosen = try legs(arena, ephemerides, sat, payload.of(sat), signals, message_policy.of(needed, &payload, sat), times, span_ms, leap);
            const slot = flight_plan.slot(sat);
            result.choices.timelines[slot] = chosen.choices;
            result.contents[slot] = chosen.contents;
        }
    }
    return result;
}

fn legs(arena: std.mem.Allocator, ephemerides: *const Ephemerides, sat: gnss_types.SatId, carried: *const signal_payload.Carried, signals: std.EnumSet(gnss_types.Signal), families: std.EnumSet(gnss_types.NavFamily), times: []const GpsTime, span_ms: u64, leap: civil.Leap) std.mem.Allocator.Error!PreparedLegs {
    var result: std.ArrayList(Leg) = .empty;
    var previous: ?Binding = null;
    for (times, 0..) |t, i| {
        const chosen = select.reference(ephemerides, sat, t, carried, signals, leap);
        const current: ?Binding = if (chosen) |reference| blk: {
            const selected = resolve.binding(ephemerides, reference, t, leap);
            break :blk .{ .reference = selected.reference, .group_delay = selected.group_delay, .sources = selected.attributes.sources(), .p1 = selected.glonass_p1 };
        } else null;
        const same = if (current) |*value| if (previous) |*last| value.sameSelection(last) else false else previous == null;
        if (i == 0 or !same) try result.append(arena, .{ .from_ms = @intCast(t.ms - times[0].ms), .binding = current });
        previous = current;
    }
    const contents = try arena.alloc([]const Content, result.items.len);
    @memset(contents, &.{});
    var first: usize = 0;
    while (first < result.items.len) {
        const selected = if (result.items[first].binding) |*value| value else {
            first += 1;
            continue;
        };
        var end = first + 1;
        while (end < result.items.len) : (end += 1) {
            const next = if (result.items[end].binding) |*value| value else break;
            if (!selected.sameValues(next, ephemerides.*)) break;
        }
        var attributes: navigation_reference.Attributes = undefined;
        const reference = selected.input(ephemerides.*, &attributes);
        var orbit: ?d1d2.Orbit = null;
        if (families.contains(.d1d2)) {
            const source = reference.kepler.record.parameters();
            if (d1d2.carried(&source)) {
                orbit = .original;
            } else {
                const until_ms = if (end < result.items.len) result.items[end].from_ms else span_ms;
                const interval: d1d2_fit.Interval = .{ .first = times[0].addMs(@intCast(result.items[first].from_ms)), .last = times[0].addMs(@intCast(until_ms)) };
                if (d1d2_fit.fitted(&source, interval)) |fitted| orbit = .{ .fitted = fitted };
            }
        }
        const prepared = try prepare(arena, reference, selected.p1, families, orbit, leap);
        for (result.items[first..end], contents[first..end]) |*leg, *content| {
            leg.binding.?.messages = prepared.choices;
            content.* = prepared.contents;
        }
        first = end;
    }
    return .{ .choices = result.items, .contents = contents };
}

fn prepare(arena: std.mem.Allocator, reference: navigation_reference.Reference, p1: u2, families: std.EnumSet(gnss_types.NavFamily), orbit: ?d1d2.Orbit, leap: civil.Leap) std.mem.Allocator.Error!PreparedBinding {
    const choices = try arena.alloc(Choice, families.count());
    const contents = try arena.alloc(Content, families.count());
    var it = families.iterator();
    var i: usize = 0;
    while (it.next()) |family| : (i += 1) switch (reference) {
        .glonass => |g| {
            const prepared = gnav.prepare(g.record, p1, g.group_delay.get(.delta_tau_n), leap);
            choices[i] = .{ .gnav = prepared.choice };
            contents[i] = .{ .gnav = prepared.content };
        },
        .kepler => |e| switch (family) {
            inline .lnav, .inav, .fnav => |f| {
                const coder = switch (f) {
                    .lnav => lnav,
                    .inav => inav,
                    .fnav => fnav,
                    else => unreachable,
                };
                const prepared = coder.prepare(e);
                choices[i] = @unionInit(Choice, @tagName(f), prepared.choice);
                contents[i] = @unionInit(Content, @tagName(f), prepared.content);
            },
            inline .cnav, .cnav2 => |f| {
                const prepared = cnvx.prepare(e, @field(records.NavSource, @tagName(f)));
                choices[i] = @unionInit(Choice, @tagName(f), prepared.choice);
                contents[i] = @unionInit(Content, @tagName(f), prepared.content);
            },
            .d1d2 => {
                const prepared = d1d2.prepare(e, orbit);
                choices[i] = .{ .d1d2 = prepared.choice };
                contents[i] = .{ .d1d2 = prepared.content };
            },
            inline .bcnav1, .bcnav2, .bcnav3 => |f| {
                const prepared = bcnav.prepare(e, @field(records.NavSource, @tagName(f)));
                choices[i] = @unionInit(Choice, @tagName(f), prepared.choice);
                contents[i] = @unionInit(Content, @tagName(f), prepared.content);
            },
            .cnav_has, .ppp_b2b, .gnav => unreachable,
        },
    };
    return .{ .choices = choices, .contents = contents };
}
