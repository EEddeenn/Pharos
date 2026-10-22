const std = @import("std");
const air = @import("domain/navigation/air");
const health = @import("domain/navigation/health");
const records = @import("domain/navigation/records");
const reference_model = @import("domain/navigation/reference");
const display_model = @import("phb/model/display");
const delay = @import("domain/navigation/group_delay");
const signal_catalog = @import("domain/signals/catalog");
const ionosphere_config = @import("simulation/model/ionosphere");
const binding = @import("simulation/tracking/binding");
const provider = @import("simulation/tracking/track");
const value = @import("products/obs/inspect/values");
const gnss_types = @import("domain/gnss_types");

const FlightPlan = @import("simulation/model/flight_plan").FlightPlan;
const GpsTime = @import("domain/time/gps").GpsTime;

const Availability = value.Availability;
const Instant = value.Instant;

const klobuchar_units = .{ .alpha = "s/semicircle^i, i=0..3", .beta = "s/semicircle^i, i=0..3" };
const nequick_units = .{ .ai0_sfu = "sfu", .ai1_sfu_per_deg = "sfu/deg", .ai2_sfu_per_deg2 = "sfu/deg^2" };
const bdgim_units = .{ .alpha_tecu = "TECU" };
const component_delay_units = .{ .term_s = "s", .code_s = "s" };
const group_delay_units = .{ .clock_reference_shift_s = "s", .transition_previous_weight = "1" };
const clock_units = .{ .bias_s = "s", .drift_s_per_s = "s/s", .relativistic_correction_s = "s" };
const model_units = .{ .position_ecef_m = "m", .velocity_ecef_m_per_s = "m/s" };
const kepler_units = .{ .iode_index = "index", .iodc_index = "index" };
const glonass_units = .{ .delta_tau_n_s = "s", .frequency_channel_index = "index", .age_days = "day" };

pub const Ionosphere = struct {
    availability: Availability,
    reason: ?value.Reason = null,
    model: ?[]const u8 = null,
    klobuchar: ?Klobuchar = null,
    nequick: ?Nequick = null,
    bdgim: ?Bdgim = null,

    pub const Klobuchar = struct {
        alpha: [4]f64,
        beta: [4]f64,
        units: @TypeOf(klobuchar_units) = klobuchar_units,
    };
    pub const Nequick = struct {
        ai0_sfu: f64,
        ai1_sfu_per_deg: f64,
        ai2_sfu_per_deg2: f64,
        units: @TypeOf(nequick_units) = nequick_units,
    };
    pub const Bdgim = struct { alpha_tecu: [9]f64, units: @TypeOf(bdgim_units) = bdgim_units };
};

pub const ComponentDelay = struct {
    availability: Availability,
    reason: ?value.Reason = null,
    term_s: ?f64 = null,
    code_s: ?f64 = null,
    units: @TypeOf(component_delay_units) = component_delay_units,
};

pub const GroupDelay = struct {
    availability: Availability,
    reason: ?value.Reason = null,
    origin: ?air.Origin = null,
    clock_reference_shift_s: ?f64 = null,
    data: ?ComponentDelay = null,
    pilot: ?ComponentDelay = null,
    carrier: ?ComponentDelay = null,
    carrier_reference_signal: ?[]const u8 = null,
    carrier_reference_component: ?gnss_types.Component = null,
    transition_previous_weight: ?f64 = null,
    blend_until: ?Instant = null,
    units: @TypeOf(group_delay_units) = group_delay_units,
};

/// Each term null where the satellite's model gives none that is finite.
pub const Clock = struct {
    bias_s: ?f64,
    drift_s_per_s: ?f64,
    relativistic_correction_s: ?f64,
    units: @TypeOf(clock_units) = clock_units,
};

pub const Model = struct {
    availability: Availability,
    reason: ?value.Reason = null,
    evaluation: enum { provider_at_receiver_epoch } = .provider_at_receiver_epoch,
    orbit_model: ?enum { kepler, glonass, precise } = null,
    position_ecef_m: ?[3]f64 = null,
    velocity_ecef_m_per_s: ?[3]f64 = null,
    clock: ?Clock = null,
    group_delay: GroupDelay,
    ionosphere: Ionosphere,
    selection_refreshed_at: ?Instant = null,
    next_selection_refresh_at: ?Instant = null,
    orbit_blend_until: ?Instant = null,
    units: @TypeOf(model_units) = model_units,
};

pub const Health = struct {
    status: health.Status,
    serves_signal: bool,
    family: ?gnss_types.NavFamily,
};

pub const Accuracy = struct {
    availability: Availability = .available,
    reason: ?value.Reason = null,
    family: ?gnss_types.NavFamily = null,
    ura_index: ?u4 = null,
    ura_ed_index: ?i5 = null,
    ura_ned0_index: ?i5 = null,
    ura_ned1_index: ?u3 = null,
    ura_ned2_index: ?u3 = null,
    sisa_index: ?u8 = null,
    sismai_index: ?u4 = null,
    sisai_oe_index: ?u5 = null,
    sisai_ocb_index: ?u5 = null,
    sisai_oc1_index: ?u3 = null,
    sisai_oc2_index: ?u3 = null,
    ft_index: ?u4 = null,
    units: @TypeOf(accuracy_units) = accuracy_units,
};

pub const DelayTerms = struct {
    tgd_l1ca: ?f64 = null,
    isc_l1ca: ?f64 = null,
    isc_l1cd: ?f64 = null,
    isc_l1cp: ?f64 = null,
    isc_l2c: ?f64 = null,
    isc_l5i5: ?f64 = null,
    isc_l5q5: ?f64 = null,
    tgd_b1cp: ?f64 = null,
    isc_b1cd: ?f64 = null,
    tgd_b2ap: ?f64 = null,
    isc_b2ad: ?f64 = null,
    tgd_b2bi: ?f64 = null,
    tgd_b1i: ?f64 = null,
    tgd_b2i: ?f64 = null,
    bgd_e1e5a: ?f64 = null,
    bgd_e1e5b: ?f64 = null,
    units: @TypeOf(delay_term_units) = delay_term_units,

    fn of(values: *const records.GroupDelays) DelayTerms {
        var out: DelayTerms = .{};
        inline for (comptime std.enums.values(records.GroupDelayTerm)) |term| {
            // A GLONASS record shows its own delta tau n.
            if (term == .delta_tau_n) continue;
            const name = comptime @tagName(term);
            @field(out, name) = values.get(term);
        }
        return out;
    }
};

pub const Kepler = struct {
    toe: Instant,
    toc: Instant,
    top: ?Instant,
    iode_index: u16,
    iodc_index: u16,
    orbit: value.Orbit,
    group_delay_terms_s: DelayTerms,
    units: @TypeOf(kepler_units) = kepler_units,

    fn of(reference: reference_model.Kepler) Kepler {
        const e = reference.record;
        return .{
            .toe = .of(e.toe),
            .toc = .of(e.toc),
            .top = if (e.top) |top| .of(top) else null,
            .iode_index = e.iode,
            .iodc_index = e.iodc,
            .orbit = .of(e.parameters()),
            .group_delay_terms_s = .of(reference.group_delay),
        };
    }
};

pub const Glonass = struct {
    tb: Instant,
    orbit: value.GlonassOrbit,
    delta_tau_n_s: ?f64,
    frequency_channel_index: i32,
    age_days: u5,
    units: @TypeOf(glonass_units) = glonass_units,

    fn of(e: *const records.GlonassEphemeris) Glonass {
        return .{
            .tb = .of(e.tb),
            .orbit = .of(e),
            .delta_tau_n_s = e.delta_tau_n,
            .frequency_channel_index = e.freq.int(),
            .age_days = e.en,
        };
    }
};

pub const Navigation = struct {
    availability: Availability,
    reason: ?value.Reason = null,
    semantics: enum { adopted_navigation_reference } = .adopted_navigation_reference,
    family: ?gnss_types.NavFamily = null,
    kepler: ?Kepler = null,
    glonass: ?Glonass = null,
    health: ?Health = null,
    accuracy: ?Accuracy = null,
};

pub const Inputs = struct {
    flight_plan: *const FlightPlan,
    ionosphere: *const ionosphere_config.Configuration,
};

pub fn model(input: Inputs, ephemeris: *provider.Track, sat: gnss_types.SatId, signal: gnss_types.Signal, t: GpsTime) Model {
    var out: Model = .{
        .availability = .unavailable,
        .reason = .no_available_record,
        .group_delay = .{ .availability = .unavailable, .reason = .no_available_record },
        .ionosphere = ionosphere(input.ionosphere, sat.system),
    };
    const current = ephemeris.current orelse return out;
    const state = ephemeris.stateAt(t);
    out.availability = .available;
    out.reason = null;
    out.orbit_model = switch (current.selection.source) {
        .kepler => .kepler,
        .glonass => .glonass,
        .precise => .precise,
    };
    // A model fed values far outside what a satellite does can give numbers that are not finite: none is written.
    out.position_ecef_m = finiteVector(state.pos.toArray());
    out.velocity_ecef_m_per_s = finiteVector(state.vel.toArray());
    out.clock = .{ .bias_s = finite(state.clock_bias_s), .drift_s_per_s = finite(state.clock_drift), .relativistic_correction_s = finite(state.rel_s) };
    out.selection_refreshed_at = .of(current.at.t);
    out.next_selection_refresh_at = .of(ephemeris.nextInstant(input.flight_plan, sat));
    if (ephemeris.orbit_transition) |transition| if (t.lessThan(transition.until)) {
        out.orbit_blend_until = .of(transition.until);
    };
    const delays = ephemeris.delaysAt(t);
    const carrier = delay.carrierCode(signal);
    out.group_delay = .{
        .availability = .available,
        .origin = delays.air[signal_catalog.slot(signal)].origin,
        .clock_reference_shift_s = delays.shift(),
        .data = componentDelay(delays, signal, .data),
        .pilot = if (signal_catalog.get(signal).hasPilot()) componentDelay(delays, signal, .pilot) else .{ .availability = .not_applicable, .reason = .signal_has_no_pilot },
        .carrier = componentDelay(delays, carrier.signal, carrier.component),
        .carrier_reference_signal = carrier.signal.name(),
        .carrier_reference_component = carrier.component,
        .transition_previous_weight = if (delays.transition) |transition| transition.weight else null,
        .blend_until = if (delays.transition != null) .of(ephemeris.delay_transition.?.until) else null,
    };
    return out;
}

pub fn navigation(display: *const display_model.Display, selected: ?*const binding.ResolvedBinding, signal: gnss_types.Signal) Navigation {
    const current = selected orelse return .{ .availability = .unavailable, .reason = .no_available_record };
    const row = current.binding.air[signal_catalog.slot(signal)];
    // The record's own reasons alone: the allocation is the channel's `broadcasts`, the family's carriage its state.
    const serves = row.status != .dead;
    return switch (current.binding.reference) {
        .kepler => |i| blk: {
            const record = &display.ephemerides.kepler[i];
            const declared = if (row.declared) |k| reference_model.attributesOf(record, &display.ephemerides.kepler[k]) else null;
            break :blk .{
                .availability = .available,
                .family = record.source().family(),
                .kepler = .of(.{ .record = record, .group_delay = &display.choice(current.leg).group_delay }),
                .health = .{ .status = row.health, .serves_signal = serves, .family = if (declared) |extra| @as(records.NavSource, extra).family() else null },
                .accuracy = if (declared) |extra| accuracy(extra) else .{ .availability = .unavailable, .reason = .accuracy_not_stated },
            };
        },
        .glonass => |i| blk: {
            const g = &display.ephemerides.glonass[i];
            break :blk .{
                .availability = .available,
                .family = .gnav,
                .glonass = .of(g),
                .health = .{ .status = row.health, .serves_signal = serves, .family = .gnav },
                .accuracy = if (g.ft) |ft| .{ .family = .gnav, .ft_index = ft } else .{ .family = .gnav, .availability = .unavailable, .reason = .accuracy_not_stated },
            };
        },
    };
}

fn finite(x: f64) ?f64 {
    return if (std.math.isFinite(x)) x else null;
}

fn finiteVector(v: [3]f64) ?[3]f64 {
    for (v) |x| if (!std.math.isFinite(x)) return null;
    return v;
}

fn componentDelay(delays: provider.Delays, signal: gnss_types.Signal, component: gnss_types.Component) ComponentDelay {
    return .{ .availability = .available, .term_s = delays.term(signal, component), .code_s = delays.code(signal, component) };
}

fn ionosphere(configuration: *const ionosphere_config.Configuration, system: gnss_types.System) Ionosphere {
    const ready = switch (configuration.*) {
        .inactive => return .{ .availability = .unavailable, .reason = .ionosphere_not_resolved },
        .ready => |*ready| ready,
    };
    const selected_model = ready.systems.get(system).model;
    var out: Ionosphere = .{ .availability = .available, .model = selected_model.name() };
    switch (selected_model) {
        .none => {
            out.availability = if (ready.requested == .auto) .not_applicable else .disabled;
            out.reason = if (ready.requested == .auto) .system_not_enabled else .ionosphere_disabled;
        },
        .klobuchar, .bds_klobuchar => {
            const c = if (selected_model == .klobuchar) ready.broadcast.klobuchar else ready.broadcast.bds_klobuchar;
            out.klobuchar = .{ .alpha = c.alpha, .beta = c.beta };
        },
        .nequick => {
            const c = ready.broadcast.nequick.?;
            out.nequick = .{ .ai0_sfu = c.ai0, .ai1_sfu_per_deg = c.ai1, .ai2_sfu_per_deg2 = c.ai2 };
        },
        .bdgim => out.bdgim = .{ .alpha_tecu = ready.broadcast.bdgim.? },
    }
    return out;
}

fn accuracy(attributes: records.SourceExtra) Accuracy {
    var out: Accuracy = .{ .family = @as(records.NavSource, attributes).family() };
    switch (attributes) {
        inline .lnav, .d1d2 => |a| out.ura_index = a.ura_index,
        inline .cnav, .cnav2 => |a| {
            out.ura_ed_index = a.ura.ed;
            out.ura_ned0_index = a.ura.ned0;
            out.ura_ned1_index = a.ura.ned1;
            out.ura_ned2_index = a.ura.ned2;
        },
        inline .inav, .fnav => |a| out.sisa_index = a.sisa_index,
        .bcnav1, .bcnav2, .bcnav3 => |a| {
            out.sismai_index = a.sismai;
            out.sisai_oe_index = a.sisai_oe;
            out.sisai_ocb_index = a.sisai_ocb;
            out.sisai_oc1_index = a.sisai_oc1;
            out.sisai_oc2_index = a.sisai_oc2;
        },
    }
    return out;
}
const accuracy_units = .{
    .ura_index = "index",
    .ura_ed_index = "index",
    .ura_ned0_index = "index",
    .ura_ned1_index = "index",
    .ura_ned2_index = "index",
    .sisa_index = "index",
    .sismai_index = "index",
    .sisai_oe_index = "index",
    .sisai_ocb_index = "index",
    .sisai_oc1_index = "index",
    .sisai_oc2_index = "index",
    .ft_index = "index",
};
const delay_term_units = .{
    .tgd_l1ca = "s",
    .isc_l1ca = "s",
    .isc_l1cd = "s",
    .isc_l1cp = "s",
    .isc_l2c = "s",
    .isc_l5i5 = "s",
    .isc_l5q5 = "s",
    .tgd_b1cp = "s",
    .isc_b1cd = "s",
    .tgd_b2ap = "s",
    .isc_b2ad = "s",
    .tgd_b2bi = "s",
    .tgd_b1i = "s",
    .tgd_b2i = "s",
    .bgd_e1e5a = "s",
    .bgd_e1e5b = "s",
};
