const std = @import("std");
const clock_reference = @import("domain/navigation/clock_reference");
const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");
const navigation_reference = @import("domain/navigation/reference");
const signal_air = @import("domain/navigation/air");
const signal_payload = @import("domain/signals/payload");
const signal_catalog = @import("domain/signals/catalog");
const precise = @import("domain/navigation/precise/product");
const antenna = @import("domain/navigation/antenna/phase_centre");
const gnav = @import("domain/messages/glonass/gnav/content");
const lnav = @import("domain/messages/gps/lnav/content");
const cnvx = @import("domain/messages/gps/cnav_common/content");
const inav = @import("domain/messages/galileo/inav/content");
const fnav = @import("domain/messages/galileo/fnav/content");
const d1d2 = @import("domain/messages/bds/d1d2/content");
const bcnav = @import("domain/messages/bds/bcnav/content");
const model = @import("phb/model/file");
const plan = @import("simulation/model/flight_plan");
const systems = @import("simulation/model/systems");
const Reference = navigation_reference.Reference;
const Row = signal_air.Row;
const ClockRef = clock_reference.ClockRef;
const ClockReferences = clock_reference.ClockReferences;
const Content = @import("domain/messages/content").Content;
const PlanBinding = @import("phb/model/plan").Binding;
const PreparedScenario = @import("simulation/model/prepared_scenario").PreparedScenario;
const PreparedMessages = @import("simulation/model/prepared_messages").PreparedMessages;
const ServicePlan = @import("simulation/model/services").ServicePlan;
const ClockPoly = @import("domain/time/clock").Poly;

pub fn build(arena: std.mem.Allocator, file: *const model.File, contents: plan.PreparedContents, prepared_messages: ?PreparedMessages) std.mem.Allocator.Error!PreparedScenario {
    const config = &file.config;
    const payload = signal_payload.at(config.start);
    const services = ServicePlan.init(config, &file.publications, &payload, file.precise != null);
    const clock_refs: ClockReferences = if (file.precise) |data| data.clock_reference else .{};
    const timelines = try arena.alloc(plan.Timeline, plan.satellite_count);
    for (gnss_types.System.all) |system| {
        var sats = system.satellites();
        while (sats.next()) |sat| {
            const index = plan.slot(sat);
            const choices = file.plan.timelines[index];
            const legs = try arena.alloc(plan.Leg, choices.len);
            for (legs, choices, contents[index], 0..) |*leg, *choice, prepared_content, i| {
                var binding_start = i;
                if (i > 0) {
                    const previous = choices[i - 1].binding;
                    const same = if (choice.binding) |*current| if (previous) |*before| current.sameValues(before, file.ephemerides) else false else previous == null;
                    if (same) binding_start = legs[i - 1].binding_start;
                }
                leg.* = .{
                    .from_ms = choice.from_ms,
                    .binding_start = binding_start,
                    .binding = if (choice.binding) |*selected| try binding(arena, selected, file.ephemerides, sat, payload.of(sat), prepared_content, file.precise != null, clock_refs.get(system)) else null,
                };
            }
            timelines[index] = .{ .sat = sat, .legs = legs };
        }
    }
    const product = if (file.precise) |data| blk: {
        const value = try arena.create(precise.Product);
        value.* = precise.Product.init(data.series, data.interval_s);
        break :blk value;
    } else null;
    var scales: std.EnumMap(gnss_types.System, ClockPoly) = .{};
    for (gnss_types.System.all) |system| switch (file.systems.scales.get(system)) {
        .record => scales.put(system, systems.scalePolynomial(&file.systems.records, file.systems.scales.get(system), config.start)),
        .zero => {},
    };
    return .{
        .config = config.*,
        .trajectory = .{ .knots = file.knots },
        .flight_plan = .{
            .start = config.start,
            .spans_ms = plan.spansMs(config.signals, services, config.duration_ms),
            .timelines = timelines,
            .scales = scales,
            .leap = file.leap,
        },
        .messages = prepared_messages,
        .services = services,
        .precise = product,
        .phase_centres = try antenna.PhaseCentres.init(arena, file.antennas, clock_refs),
        .payload = payload,
    };
}

pub fn projectContents(arena: std.mem.Allocator, file: *const model.File) std.mem.Allocator.Error!plan.PreparedContents {
    var result: plan.PreparedContents = undefined;
    for (file.plan.timelines, &result) |legs, *timeline| {
        const contents = try arena.alloc([]const Content, legs.len);
        for (legs, contents) |*leg, *output| {
            const selected = if (leg.binding) |*value| value else {
                output.* = &.{};
                continue;
            };
            var attributes: navigation_reference.Attributes = undefined;
            const reference = selected.input(file.ephemerides, &attributes);
            const values = try arena.alloc(Content, selected.messages.len);
            for (selected.messages, values) |choice, *value| value.* = switch (choice) {
                .lnav => |chosen| .{ .lnav = lnav.project(reference.kepler, chosen) },
                .cnav => |chosen| .{ .cnav = cnvx.project(reference.kepler, .cnav, chosen) },
                .cnav2 => |chosen| .{ .cnav2 = cnvx.project(reference.kepler, .cnav2, chosen) },
                .inav => |chosen| .{ .inav = inav.project(reference.kepler, chosen) },
                .fnav => |chosen| .{ .fnav = fnav.project(reference.kepler, chosen) },
                .d1d2 => |chosen| .{ .d1d2 = d1d2.project(reference.kepler, chosen) },
                inline .bcnav1, .bcnav2, .bcnav3 => |chosen, family| @unionInit(Content, @tagName(family), bcnav.project(reference.kepler, @field(records.NavSource, @tagName(family)), chosen)),
                .gnav => |chosen| .{ .gnav = gnav.project(reference.glonass.record, selected.p1, selected.group_delay.get(.delta_tau_n), file.leap, chosen) },
                .cnav_has, .ppp_b2b => unreachable,
            };
            output.* = values;
        }
        timeline.* = contents;
    }
    return result;
}

fn binding(arena: std.mem.Allocator, choice: *const PlanBinding, ephemerides: records.Ephemerides, sat: gnss_types.SatId, carried: *const signal_payload.Carried, contents: []const Content, has_precise: bool, clock_ref: ClockRef) std.mem.Allocator.Error!plan.Binding {
    var attributes: navigation_reference.Attributes = undefined;
    const reference = choice.input(ephemerides, &attributes);
    const air = try signal_air.rows(arena, reference, sat, carried, contents);
    return .{
        .reference = choice.reference,
        .air = air,
        .contents = contents,
        .flown = flown(reference, air, has_precise, clock_ref),
        .freq = switch (reference) {
            .kepler => null,
            .glonass => |g| g.record.freq,
        },
    };
}

fn flown(reference: Reference, air: []const Row, has_precise: bool, clock_ref: ClockRef) plan.Flown {
    if (has_precise) {
        const pair = clock_ref.pair();
        return .{ .precise = .{
            .delay_shift_s = clock_ref.offset(air[signal_catalog.slot(pair[0])].delay_s.get(.data), air[signal_catalog.slot(pair[1])].delay_s.get(.data)),
        } };
    }
    return switch (reference) {
        .kepler => |e| .{ .kepler = e.record.parameters() },
        .glonass => |g| .{ .glonass = .{ .tb = g.record.tb, .pos = g.record.pos, .vel = g.record.vel, .acc = g.record.acc, .clock = g.record.clock() } },
    };
}
