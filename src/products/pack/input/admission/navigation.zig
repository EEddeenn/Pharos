const std = @import("std");
const ionosphere_nequick = @import("domain/propagation/ionosphere/nequick");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const field = @import("base/binary/field");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const nequick_fields = @import("domain/messages/galileo/fields/ionosphere");
const bdgim_fields = @import("domain/messages/bds/fields/ionosphere");
const records = @import("domain/navigation/records");
const auxiliary = @import("domain/navigation/system_data");
const lnav_content = @import("domain/messages/gps/lnav/content");
const lnav_fields = @import("domain/messages/gps/lnav/fields");
const cnvx = @import("domain/messages/gps/cnav_common/content");
const galileo = @import("domain/messages/galileo/fields/ephemeris");
const galileo_almanac = @import("domain/messages/galileo/fields/almanac");
const d1d2_fields = @import("domain/messages/bds/d1d2/fields");
const d1d2_content = @import("domain/messages/bds/d1d2/content");
const d1d2_pages = @import("domain/messages/bds/d1d2/pages");
const bds_records = @import("domain/navigation/records/bds");
const bds_parameters = @import("domain/messages/bds/fields/time");
const bcnav = @import("domain/messages/bds/fields/ephemeris");
const gnav_content = @import("domain/messages/glonass/gnav/content");
const gnav_fields = @import("domain/messages/glonass/gnav/fields");
const glonass_orbit = @import("domain/navigation/orbit/glonass");
const Klobuchar = @import("domain/propagation/ionosphere/klobuchar").Model;

pub const half_week_s = 302_400;

const delay_limit_s = 0x1p-23;
const d1d2_tgd_limit_s = 512e-10;
// GNAV's Delta tau_n has four magnitude bits of 2^-30 s: a value fits while it rounds to 15 units at most.
const delta_tau_n_limit_s = 15.5 * 0x1p-30;

pub fn kepler(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    if (e.parameters().rawMisfit()) |name| return name;
    if (!(@abs(e.toc.secondsSince(e.toe)) <= half_week_s)) return "toc";
    if (e.top) |top| if (!(@abs(top.secondsSince(e.toe)) <= half_week_s)) return "top";

    const scale = e.weekScale();
    const step = epochStepMs(e.source());
    if (!onGrid(e.toe, scale, step)) return "toe";
    if (!onGrid(e.toc, scale, step)) return "toc";
    if (e.top) |top| if (!onGrid(top, scale, step)) return "top";

    if (groupDelays(&e.group_delay)) |term| return term;
    return switch (e.extra) {
        .lnav => rates(e) orelse lnav_content.misfit(e),
        .cnav, .cnav2 => cnvx.misfit(e),
        .inav, .fnav => rates(e) orelse galileo.misfit(e),
        .d1d2 => rates(e) orelse d1d2_fields.misfit(e),
        .bcnav1, .bcnav2, .bcnav3 => bcnav.misfit(e),
    };
}

pub fn glonass(g: *const records.GlonassEphemeris, leap: civil.Leap) ?[:0]const u8 {
    if (gnav_content.misfit(g, leap)) |name| return name;
    return glonass_orbit.misfit(g);
}

pub fn almanac(a: *const records.KeplerAlmanac) ?[:0]const u8 {
    return switch (a.sat.system) {
        .gps => field.misfit(records.KeplerAlmanac, &lnav_fields.almanac_page, a),
        .gal => galileo_almanac.misfit(a.*),
        .bds => d1d2_pages.almanacMisfit(a.*, bds_records.isGeo(a.sat.prn())),
        .glo => null,
    };
}

pub fn glonassAlmanac(a: *const records.GlonassAlmanac) ?[:0]const u8 {
    if (a.n4 < 1) return "n4";
    if (a.na < 1 or a.na > 1461) return "na";
    return field.misfit(records.GlonassAlmanac, &gnav_fields.almanac_even, a) orelse field.misfit(records.GlonassAlmanac, &gnav_fields.almanac_odd, a);
}

pub fn timeOffset(offset: auxiliary.TimeOffset) ?[:0]const u8 {
    if (coefficients(offset.kind, offset.a0, offset.a1, offset.a2)) |name| return name;
    const reference = offset.reference orelse return null;
    const transmitted = offset.transmitted orelse return null;
    if (!transmissionNear(reference, transmitted)) return "t_tm";
    return null;
}

pub fn eop(e: *const auxiliary.Eop) ?[:0]const u8 {
    const candidate = bds_parameters.eopCandidate(e.*);
    if (field.misfit(bds_parameters.Eop, &bds_parameters.eop, &candidate)) |name| return name;
    if (!transmissionNear(e.reference, e.transmitted)) return "t_tm";
    return null;
}

pub fn klobuchar(m: Klobuchar) ?[:0]const u8 {
    const c = klobuchar_fields.Coefficients.of(m);
    return field.misfit(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, &c);
}

pub fn nequick(c: ionosphere_nequick.Coefficients) ?[:0]const u8 {
    return field.misfit(ionosphere_nequick.Coefficients, &nequick_fields.rows, &c);
}

pub fn bdgim(c: [9]f64) ?[:0]const u8 {
    return field.misfit(bdgim_fields.Coefficients, &bdgim_fields.bdgim, &c);
}

pub fn broadcastIono(b: ionosphere_model.SuppliedCoefficients) ?[:0]const u8 {
    if (b.klobuchar) |m| if (klobuchar(m)) |name| return name;
    if (b.bds_klobuchar) |m| if (klobuchar(m)) |name| return name;
    if (b.nequick) |c| if (nequick(c)) |name| return name;
    if (b.bdgim) |c| if (bdgim(c)) |name| return name;
    return null;
}

fn groupDelays(delays: *const records.GroupDelays) ?[:0]const u8 {
    for (std.enums.values(records.GroupDelayTerm)) |term| {
        const value = delays.get(term) orelse continue;
        if (!(@abs(value) < delayLimit(term))) return records.GroupDelayTerm.words.get(term);
    }
    return null;
}

fn epochStepMs(source: records.NavSource) u32 {
    return switch (source) {
        .lnav => lnav_content.toe_step_ms,
        .cnav, .cnav2, .bcnav1, .bcnav2, .bcnav3 => records.epoch_step_ms,
        .d1d2 => d1d2_content.toe_step_ms,
        .inav, .fnav => galileo.toe_step_ms,
    };
}

fn onGrid(t: time.GpsTime, scale: time.WeekScale, step_ms: u32) bool {
    const st = t.inScale(scale);
    return st.sub_ms == 0 and st.ms % step_ms == 0;
}

fn delayLimit(term: records.GroupDelayTerm) f64 {
    return switch (term) {
        .tgd_b1i, .tgd_b2i => d1d2_tgd_limit_s,
        .delta_tau_n => delta_tau_n_limit_s,
        else => delay_limit_s,
    };
}

fn rates(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    if (e.a_dot != 0) return "a_dot";
    if (e.delta_n_dot != 0) return "delta_n_dot";
    return null;
}

fn offsetLimits(kind: auxiliary.OffsetKind) [3]f64 {
    return switch (kind) {
        .gput, .bdut => .{ 0x1p1, 0x1p-27, 0x1p-62 },
        .gaut => .{ 0x1p1, 0x1p-27, 0 },
        .gagp => .{ 0x1p-20, 0x1p-39, 0x1p-62 },
        .bdgp, .bdga, .bdgl => .{ 0x1p-20, 3.2768e-6, 0x1p-62 },
        .glut => .{ 1, 0, 0 },
        .glgp => .{ 0x1p-9, 0, 0 },
    };
}

fn transmissionNear(reference: time.GpsTime, transmitted: time.GpsTime) bool {
    return @abs(transmitted.ms -| reference.ms) <= auxiliary.max_transmission_offset_ms;
}

fn coefficients(kind: auxiliary.OffsetKind, a0: f64, a1: f64, a2: f64) ?[:0]const u8 {
    const limits = offsetLimits(kind);
    const slack = 1 + 1e-9;
    if (!(@abs(a0) <= limits[0] * slack)) return "a0";
    if (!(@abs(a1) <= limits[1] * slack)) return "a1";
    if (!(@abs(a2) <= limits[2] * slack)) return "a2";
    switch (kind) {
        .glut => if (gnav_fields.scaleMisfit(-a0, 0) != null) return "a0",
        .glgp => if (gnav_fields.scaleMisfit(0, a0) != null) return "a0",
        else => {},
    }
    return null;
}
