const core = @import("shared").core;
const gnss = @import("shared").gnss;
const types = core.types;
const GpsTime = core.time.GpsTime;
const constants = core.constants;
const Ecef = core.coord.Ecef;
const provider = @import("shared").track.provider;
const Parameters = gnss.kepler_parameters.Parameters;

pub const Relativity = enum { icd_periodic, dot_product };

pub const Correction = struct {
    sat: types.SatId,
    record: gnss.reference.Kepler,
    delays: provider.Delays,
    brdc_pos: Ecef,
    brdc_vel: Ecef,
    delta_pos: Ecef,
    clock_delta_m: f64,

    pub fn ntw(self: Correction) [3]f64 {
        const e_t = self.brdc_vel.unit();
        const e_w = self.brdc_pos.cross(self.brdc_vel).unit();
        const e_n = e_t.cross(e_w);
        return .{ self.delta_pos.dot(e_n), self.delta_pos.dot(e_t), self.delta_pos.dot(e_w) };
    }

    pub fn radialAlongCross(self: Correction) [3]f64 {
        const e_r = self.brdc_pos.unit();
        const e_c = self.brdc_pos.cross(self.brdc_vel).unit();
        const e_a = e_c.cross(e_r);
        return .{ -self.delta_pos.dot(e_r), -self.delta_pos.dot(e_a), -self.delta_pos.dot(e_c) };
    }

    pub fn equivalentClock(self: Correction, rx: Ecef) f64 {
        const los = self.brdc_pos.sub(rx).unit();
        return self.clock_delta_m - los.dot(self.delta_pos);
    }
};

pub fn compute(track: *provider.Track, t: GpsTime, relativity: Relativity, scale_s: f64) ?Correction {
    const sel = track.current orelse return null;
    return switch (sel.record) {
        .kepler => |k| correct(track, sel.sat, k, &k.record.parameters(), t, relativity, scale_s),
        .glonass => null,
    };
}

pub fn against(track: *provider.Track, record: gnss.reference.Kepler, reference: *const Parameters, t: GpsTime, relativity: Relativity, scale_s: f64) ?Correction {
    const sel = track.current orelse return null;
    if (sel.record == .glonass) return null;
    return correct(track, sel.sat, record, reference, t, relativity, scale_s);
}

fn correct(track: *provider.Track, sat: types.SatId, record: gnss.reference.Kepler, reference: *const Parameters, t: GpsTime, relativity: Relativity, scale_s: f64) ?Correction {
    if (record.record.source() == .lnav) {
        const described = gnss.gps.lnav.described(record);
        if (!gnss.gps.lnav.delayFits(&described)) return null;
    }
    const delays = track.delaysAt(t);
    const brdc_orbit = gnss.kepler.Orbit.fromParameters(reference);
    const brdc = brdc_orbit.state(t);
    const brdc_rel = switch (relativity) {
        .icd_periodic => brdc.rel_s,
        .dot_product => -2.0 * brdc.pos.dot(brdc.vel) / (constants.light_speed * constants.light_speed),
    };
    const brdc_clock = reference.clock().bias(t) + brdc_rel;
    const truth = track.stateAt(t);
    const truth_clock = truth.clock_bias_s - scale_s + delays.shift() + truth.rel_s;
    return .{
        .sat = sat,
        .record = record,
        .delays = delays,
        .brdc_pos = brdc.pos,
        .brdc_vel = brdc.vel,
        .delta_pos = truth.pos.sub(brdc.pos),
        .clock_delta_m = constants.light_speed * (truth_clock - brdc_clock),
    };
}
