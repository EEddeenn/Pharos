const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const records = gnss.records;
const auxiliary = gnss.auxiliary;
const precise = @import("precise.zig");
const antex = @import("antex.zig");

pub const NavSet = struct {
    kepler: []const records.KeplerEphemeris,
    glonass: []const records.GlonassEphemeris,
    glonass_freq: [24]?types.FreqId = @splat(null),
    time_offsets: []const auxiliary.TimeOffset = &.{},
    eops: []const auxiliary.Eop = &.{},
    precise: ?*const precise.Product = null,
    antenna: ?antex.Antex = null,

    pub fn clockReference(self: *const NavSet, system: types.System) gnss.delay.ClockRef {
        return if (self.precise) |product| product.clock_ref.get(system) else gnss.delay.ClockRef.defaults.get(system);
    }

    pub fn phaseCentre(self: *const NavSet, sat: types.SatId, t: GpsTime) ?antex.PhaseCentre {
        const atx = self.antenna orelse return null;
        return antex.phaseCentre(atx, sat, t, self.clockReference(sat.system));
    }

    pub fn timeOffset(self: NavSet, kind: auxiliary.OffsetKind, source: ?types.System, t: GpsTime) ?auxiliary.TimeOffset {
        var best: ?auxiliary.TimeOffset = null;
        for (self.time_offsets) |offset| {
            if (offset.kind != kind) continue;
            if (source != null and offset.source != null and offset.source != source) continue;
            if (offset.transmitted) |at| {
                if (t.lessThan(at)) continue;
                if (best) |previous| if (previous.transmitted) |before| {
                    if (!before.lessThan(at)) continue;
                };
            } else if (best != null) continue;
            best = offset;
        }
        return best;
    }

    pub fn eop(self: NavSet, system: ?types.System, t: GpsTime) ?auxiliary.Eop {
        var best: ?auxiliary.Eop = null;
        for (self.eops) |record| {
            if (system) |s| if (record.source != s) continue;
            if (t.lessThan(record.transmitted)) continue;
            if (best) |previous| if (!previous.transmitted.lessThan(record.transmitted)) continue;
            best = record;
        }
        return best;
    }

    pub fn utc(self: NavSet, system: types.System, t: GpsTime, leap: core.civil.Leap) ?auxiliary.UtcParams {
        const kind: auxiliary.OffsetKind = switch (system) {
            .gps => .gput,
            .gal => .gaut,
            .bds => .bdut,
            .glo => .glut,
        };
        const offset = self.timeOffset(kind, system, t) orelse return null;
        const reference = offset.reference orelse return null;
        const stamp = reference.inScale(if (system == .bds) .bds else .gps);
        return .{
            .a0 = offset.a0,
            .a1 = offset.a1,
            .a2 = offset.a2,
            .tot_s = stamp.ms / 1000,
            .wn_t = @intCast(@mod(stamp.period, core.time.week_modulus_16)),
            .leap = auxiliary.LeapSecondSchedule.of(leap),
        };
    }

    pub fn validate(self: *const NavSet, leap: core.civil.Leap) ?[]const u8 {
        for (self.kepler) |*e| {
            if (e.sat.system != e.source().system() or !e.sat.valid()) return "a Keplerian record names a satellite of another system than its source";
            if (gnss.plausible.kepler(e) != null) return "a Keplerian record has a field outside its ICD field, or an orbit outside the propagator's domain";
        }
        for (self.glonass) |*g| {
            if (g.sat.system != .glo or !g.sat.valid()) return "a GLONASS record names another system's satellite";
            if (gnss.plausible.glonass(g, leap) != null) return "a GLONASS record has a field outside its ICD field, or an orbit outside the propagator's domain";
        }
        for (self.glonass_freq) |entry| if (entry) |k| if (!k.valid()) return "a GLONASS frequency number is outside its range";
        for (self.time_offsets) |o| if (gnss.plausible.timeOffset(o) != null) return "a time offset has a coefficient outside its field, or a transmission time far from its reference";
        for (self.eops) |*e| if (gnss.plausible.eop(e) != null) return "an EOP record has a field outside its ICD field, or a transmission time far from its reference";
        if (self.antenna) |atx| if (atx.validate()) |why| return why;
        if (self.precise) |product| return product.validate();
        return null;
    }
};
