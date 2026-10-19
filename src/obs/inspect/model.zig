const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const bundle = shared.bundle;
const provider = shared.track.provider;
const value = @import("value.zig");
const Availability = value.Availability;
const Instant = value.Instant;
const types = core.types;
const GpsTime = core.time.GpsTime;

const klobuchar_units = .{ .alpha = "s/semicircle^i, i=0..3", .beta = "s/semicircle^i, i=0..3" };
const nequick_units = .{ .ai0_sfu = "sfu", .ai1_sfu_per_deg = "sfu/deg", .ai2_sfu_per_deg2 = "sfu/deg^2" };
const bdgim_units = .{ .alpha_tecu = "TECU" };
const component_delay_units = .{ .term_s = "s", .code_s = "s" };
const group_delay_units = .{ .clock_reference_shift_s = "s", .transition_previous_weight = "1" };
const clock_units = .{ .bias_s = "s", .drift_s_per_s = "s/s", .relativistic_correction_s = "s" };
const model_units = .{ .position_ecef_m = "m", .velocity_ecef_m_per_s = "m/s" };
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
    clock_reference_shift_s: ?f64 = null,
    data: ?ComponentDelay = null,
    pilot: ?ComponentDelay = null,
    carrier: ?ComponentDelay = null,
    carrier_reference_signal: ?[]const u8 = null,
    carrier_reference_component: ?types.Component = null,
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
    status: gnss.health.Status,
    serves_signal: bool,
    family: types.NavFamily,
};

pub const Accuracy = struct {
    availability: Availability = .available,
    reason: ?value.Reason = null,
    family: types.NavFamily,
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

    fn of(values: *const gnss.records.GroupDelays) DelayTerms {
        var out: DelayTerms = .{};
        inline for (comptime std.meta.tags(gnss.records.GroupDelayTerm)) |term| {
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

    fn of(reference: gnss.reference.Kepler) Kepler {
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

    fn of(e: *const gnss.records.GlonassEphemeris) Glonass {
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
    family: ?types.NavFamily = null,
    kepler: ?Kepler = null,
    glonass: ?Glonass = null,
    health: ?Health = null,
    accuracy: ?Accuracy = null,
};

pub const Needs = struct { model: bool, navigation: bool };
pub const Result = struct { model: ?Model = null, navigation: ?Navigation = null };

pub fn project(b: *const bundle.Bundle, ephemeris: *const provider.Track, state: ?provider.State, sat: types.SatId, signal: types.Signal, t: GpsTime, needs: Needs) Result {
    return .{
        .model = if (needs.model) modelValue(b, ephemeris, state, sat, signal, t) else null,
        .navigation = if (needs.navigation) if (ephemeris.current) |current| navigation(current.record, signal) else .{ .availability = .unavailable, .reason = .no_available_record } else null,
    };
}

fn modelValue(b: *const bundle.Bundle, ephemeris: *const provider.Track, sampled: ?provider.State, sat: types.SatId, signal: types.Signal, t: GpsTime) Model {
    var out: Model = .{
        .availability = .unavailable,
        .reason = .no_available_record,
        .group_delay = .{ .availability = .unavailable, .reason = .no_available_record },
        .ionosphere = ionosphere(b.scenario.ionosphere, sat.system),
    };
    const current = ephemeris.current orelse return out;
    const state = sampled.?;
    out.availability = .available;
    out.reason = null;
    out.orbit_model = switch (current.source) {
        .kepler => .kepler,
        .glonass => .glonass,
        .precise => .precise,
    };
    // A model fed values far outside what a satellite does can give numbers that are not finite: none is written.
    out.position_ecef_m = finiteVector(state.pos.toArray());
    out.velocity_ecef_m_per_s = finiteVector(state.vel.toArray());
    out.clock = .{ .bias_s = finite(state.clock_bias_s), .drift_s_per_s = finite(state.clock_drift), .relativistic_correction_s = finite(state.rel_s) };
    if (ephemeris.current_at) |at| out.selection_refreshed_at = .of(at.t);
    out.next_selection_refresh_at = .of(ephemeris.nextInstant(b, sat));
    if (ephemeris.previous != null and t.lessThan(ephemeris.orbit_blend_until)) out.orbit_blend_until = .of(ephemeris.orbit_blend_until);
    const delays = ephemeris.delaysAt(t);
    const carrier = gnss.delay.carrierCode(signal);
    out.group_delay = .{
        .availability = .available,
        .clock_reference_shift_s = delays.shift(),
        .data = componentDelay(delays, signal, .data),
        .pilot = if (gnss.spec.get(signal).hasPilot()) componentDelay(delays, signal, .pilot) else .{ .availability = .not_applicable, .reason = .signal_has_no_pilot },
        .carrier = componentDelay(delays, carrier.signal, carrier.component),
        .carrier_reference_signal = carrier.signal.name(),
        .carrier_reference_component = carrier.component,
        .transition_previous_weight = if (delays.transition) |transition| transition.weight else null,
        .blend_until = if (delays.transition != null) .of(ephemeris.delay_blend_until) else null,
    };
    return out;
}

fn finite(x: f64) ?f64 {
    return if (std.math.isFinite(x)) x else null;
}

fn finiteVector(v: [3]f64) ?[3]f64 {
    for (v) |x| if (!std.math.isFinite(x)) return null;
    return v;
}

fn componentDelay(delays: provider.Delays, signal: types.Signal, component: types.Component) ComponentDelay {
    if (delays.record.delay(signal, component) == null) return .{ .availability = .unavailable, .reason = .missing_group_delay };
    return .{ .availability = .available, .term_s = delays.term(signal, component), .code_s = delays.code(signal, component) };
}

fn ionosphere(configuration: bundle.ionosphere.Configuration, system: types.System) Ionosphere {
    const ready = switch (configuration) {
        .inactive => return .{ .availability = .unavailable, .reason = .ionosphere_not_resolved },
        .ready => |ready| ready,
    };
    const model = ready.systems.get(system).model;
    var out: Ionosphere = .{ .availability = .available, .model = model.name() };
    switch (model) {
        .none => {
            out.availability = if (ready.requested == .auto) .not_applicable else .disabled;
            out.reason = if (ready.requested == .auto) .system_not_enabled else .ionosphere_disabled;
        },
        .klobuchar, .bds_klobuchar => {
            const c = if (model == .klobuchar) ready.broadcast.klobuchar else ready.broadcast.bds_klobuchar;
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

fn navigation(record: shared.track.selection.Record, signal: types.Signal) Navigation {
    return switch (record) {
        .kepler => |reference| blk: {
            const attributes = reference.attributesFor(signal);
            break :blk .{
                .availability = .available,
                .family = reference.record.source().family(),
                .kepler = .of(reference),
                .health = .{ .status = attributes.signalStatus(signal), .serves_signal = reference.serves(signal), .family = @as(gnss.records.NavSource, attributes).family() },
                .accuracy = accuracy(attributes, signal),
            };
        },
        .glonass => |g| .{
            .availability = .available,
            .family = .gnav,
            .glonass = .of(g),
            .health = .{ .status = gnss.health.flagged(g.health), .serves_signal = record.serves(signal), .family = .gnav },
            .accuracy = if (g.ft) |ft| .{ .family = .gnav, .ft_index = ft } else .{ .family = .gnav, .availability = .unavailable, .reason = .accuracy_not_stated },
        },
    };
}

fn accuracy(attributes: gnss.records.SourceExtra, signal: types.Signal) Accuracy {
    var out: Accuracy = .{ .family = @as(gnss.records.NavSource, attributes).family() };
    switch (attributes) {
        inline .lnav, .d1d2 => |a| out.ura_index = a.ura_index,
        inline .cnav, .cnav2 => |a| {
            out.ura_ed_index = a.ura.ed;
            out.ura_ned0_index = a.ura.ned0;
            out.ura_ned1_index = a.ura.ned1;
            out.ura_ned2_index = a.ura.ned2;
        },
        .inav => |a| {
            if (signal == .e5a) {
                if (a.e5a) |declaration| {
                    out.sisa_index = declaration.sisa_index;
                } else {
                    out.availability = .unavailable;
                    out.reason = .accuracy_not_stated_for_signal;
                }
            } else out.sisa_index = a.sisa_index;
        },
        .fnav => |a| out.sisa_index = a.sisa_index,
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
