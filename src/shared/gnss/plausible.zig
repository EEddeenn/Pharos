const std = @import("std");
const time = @import("../core.zig").time;
const civil = @import("../core.zig").civil;
const field = @import("../codec.zig").field;
const iono = @import("../core.zig").iono;
const klobuchar_fields = @import("klobuchar_fields.zig");
const nequick_fields = @import("galileo/iono_fields.zig");
const bdgim_fields = @import("bds/iono_fields.zig");
const records = @import("records.zig");
const auxiliary = @import("auxiliary.zig");
const kepler_orbit = @import("kepler.zig");
const lnav = @import("gps/lnav.zig");
const cnvx = @import("gps/cnvx.zig");
const galileo = @import("galileo/ephemeris_fields.zig");
const galileo_almanac = @import("galileo/almanac_fields.zig");
const d1d2 = @import("bds/d1d2.zig");
const bds_records = @import("bds/records.zig");
const bds_parameters = @import("bds/time_parameters.zig");
const bcnav = @import("bds/ephemeris_fields.zig");
const gnav = @import("glonass/gnav.zig");
const glonass_orbit = @import("glonass/orbit.zig");

pub const half_week_s = 302_400;

const delay_limit_s = 0x1p-23;
const d1d2_tgd_limit_s = 512e-10;
// GNAV's Delta tau_n has four magnitude bits of 2^-30 s: a value fits while it rounds to 15 units at most.
const delta_tau_n_limit_s = 15.5 * 0x1p-30;

fn epochStepMs(source: records.NavSource) u32 {
    return switch (source) {
        .lnav => lnav.toe_step_ms,
        .cnav, .cnav2, .bcnav1, .bcnav2, .bcnav3 => records.epoch_step_ms,
        .d1d2 => d1d2.toe_step_ms,
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

pub fn groupDelays(delays: *const records.GroupDelays) ?[:0]const u8 {
    for (std.enums.values(records.GroupDelayTerm)) |term| {
        const value = delays.get(term) orelse continue;
        if (!(@abs(value) < delayLimit(term))) return records.GroupDelayTerm.words.get(term);
    }
    return null;
}

pub fn kepler(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    if (kepler_orbit.misfit(e)) |name| return name;
    if (!(@abs(e.toc.secondsSince(e.toe)) <= half_week_s)) return "toc";
    if (e.top) |top| if (!(@abs(top.secondsSince(e.toe)) <= half_week_s)) return "top";

    const scale = e.weekScale();
    const step = epochStepMs(e.source());
    if (!onGrid(e.toe, scale, step)) return "toe";
    if (!onGrid(e.toc, scale, step)) return "toc";
    if (e.top) |top| if (!onGrid(top, scale, step)) return "top";

    if (groupDelays(&e.group_delay)) |term| return term;
    return switch (e.extra) {
        .lnav => rates(e) orelse lnav.misfit(e),
        .cnav, .cnav2 => cnvx.misfit(e),
        .inav, .fnav => rates(e) orelse galileo.misfit(e),
        .d1d2 => rates(e) orelse d1d2.misfit(e),
        .bcnav1, .bcnav2, .bcnav3 => |x| if (x.sat_type == null) "sat_type" else bcnav.misfit(e),
    };
}

fn rates(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    if (e.a_dot != 0) return "a_dot";
    if (e.delta_n_dot != 0) return "delta_n_dot";
    return null;
}

pub fn glonass(g: *const records.GlonassEphemeris, leap: civil.Leap) ?[:0]const u8 {
    if (!g.freq.valid()) return "freq";
    if (gnav.misfit(g, leap)) |name| return name;
    return glonass_orbit.misfit(g);
}

pub fn almanac(a: *const records.KeplerAlmanac) ?[:0]const u8 {
    return switch (a.sat.system) {
        .gps => field.misfit(records.KeplerAlmanac, &lnav.almanac_page, a),
        .gal => galileo_almanac.misfit(a.*),
        .bds => d1d2.almanacMisfit(a.*, bds_records.isGeo(a.sat.prn())),
        .glo => null,
    };
}

pub fn glonassAlmanac(a: *const records.GlonassAlmanac) ?[:0]const u8 {
    if (a.n4 < 1) return "n4";
    if (a.na < 1 or a.na > 1461) return "na";
    return field.misfit(records.GlonassAlmanac, &gnav.almanac_even, a) orelse field.misfit(records.GlonassAlmanac, &gnav.almanac_odd, a);
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

pub fn timeOffset(offset: auxiliary.TimeOffset) ?[:0]const u8 {
    const limits = offsetLimits(offset.kind);
    const slack = 1 + 1e-9;
    if (!(@abs(offset.a0) <= limits[0] * slack)) return "a0";
    if (!(@abs(offset.a1) <= limits[1] * slack)) return "a1";
    if (!(@abs(offset.a2) <= limits[2] * slack)) return "a2";

    switch (offset.kind) {
        .glut => if (gnav.scaleMisfit(-offset.a0, 0) != null) return "a0",
        .glgp => if (gnav.scaleMisfit(0, offset.a0) != null) return "a0",
        else => {},
    }

    const reference = offset.reference orelse return null;
    const transmitted = offset.transmitted orelse return null;
    if (!transmissionNear(reference, transmitted)) return "t_tm";
    return null;
}

pub fn eop(e: *const auxiliary.Eop) ?[:0]const u8 {
    if (e.dut1_kind == null) return "dut1";
    if (field.misfit(auxiliary.Eop, &bds_parameters.eop, e)) |name| return name;
    if (!transmissionNear(e.reference, e.transmitted)) return "t_tm";
    return null;
}

pub fn klobuchar(m: iono.klobuchar.Model) ?[:0]const u8 {
    const c = klobuchar_fields.Coefficients.of(m);
    return field.misfit(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, &c);
}

pub fn nequick(c: iono.nequick.Coefficients) ?[:0]const u8 {
    return field.misfit(nequick_fields.Coefficients, &nequick_fields.rows, &c);
}

pub fn bdgim(c: [9]f64) ?[:0]const u8 {
    return field.misfit(bdgim_fields.Coefficients, &bdgim_fields.bdgim, &c);
}

pub fn broadcastIono(b: iono.Broadcast) ?[:0]const u8 {
    if (b.klobuchar) |m| if (klobuchar(m)) |name| return name;
    if (b.bds_klobuchar) |m| if (klobuchar(m)) |name| return name;
    if (b.nequick) |c| if (nequick(c)) |name| return name;
    if (b.bdgim) |c| if (bdgim(c)) |name| return name;
    return null;
}
