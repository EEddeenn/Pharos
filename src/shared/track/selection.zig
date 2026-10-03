const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const bundle = @import("../bundle.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const kepler = gnss.kepler;
const glonass = gnss.glonass.orbit;
const clock = core.clock;
const records = gnss.records;
const precise = bundle.precise;

pub const Source = union(enum) {
    kepler: struct { orbit: kepler.Orbit, clock: clock.Poly },
    glonass: struct { orbit: glonass.Orbit, clock: clock.Poly },
    precise: precise.Handle,
};

pub const Record = union(enum) {
    kepler: gnss.reference.Kepler,
    glonass: *const records.GlonassEphemeris,

    pub fn freq(self: Record) ?types.FreqId {
        return switch (self) {
            .kepler => null,
            .glonass => |g| g.freq,
        };
    }

    pub fn serves(self: Record, signal: types.Signal) bool {
        return switch (self) {
            .kepler => |k| k.serves(signal),
            .glonass => true,
        };
    }

    pub fn delay(self: Record, signal: types.Signal, component: types.Component) ?f64 {
        return switch (self) {
            .kepler => |k| k.delay(signal, component),
            .glonass => |g| gnss.delay.forGlonass(g, signal),
        };
    }

    pub fn sameDelays(self: Record, other: Record) bool {
        const own = self.system();
        if (other.system() != own) return false;
        for (std.meta.tags(types.Signal)) |signal| {
            if (signal.system() != own) continue;
            for (std.meta.tags(types.Component)) |component| {
                if (!std.meta.eql(self.delay(signal, component), other.delay(signal, component))) return false;
            }
        }
        return true;
    }

    fn system(self: Record) types.System {
        return switch (self) {
            .kepler => |k| k.record.sat.system,
            .glonass => |g| g.sat.system,
        };
    }
};

const Identity = union(enum) { record: bundle.plan.Ref, product };

pub const Selection = struct {
    sat: types.SatId,
    source: Source,
    identity: Identity,
    record: Record,
    delay_shift_s: f64 = 0,
    phase_centre: ?bundle.antex.PhaseCentre = null,
};

pub const Span = struct { from: GpsTime, until: GpsTime };

pub fn resolve(b: *const bundle.Bundle, sat: types.SatId, t: GpsTime, span: Span) ?Selection {
    const set = &b.navigation;
    const binding = b.plan.bindingAt(sat, t) orelse return null;
    const ref = binding.reference;
    const record: Record = switch (ref) {
        .kepler => .{ .kepler = binding.kepler(set).? },
        .glonass => |i| .{ .glonass = &set.glonass[i] },
    };
    const centre = set.phaseCentre(sat, t);
    if (set.precise) |product| {
        const clock_ref = set.clockReference(sat.system);
        const pair = clock_ref.pair();
        const shift = clock_ref.offset(record.delay(pair[0], .data), record.delay(pair[1], .data)) orelse return null;
        const handle = product.handle(
            sat,
            span.from,
            span.until,
            if (centre) |c| .{ .body_m = c.reference_m, .law = c.law } else null,
        ) orelse return null;

        return .{
            .sat = sat,
            .source = .{ .precise = handle },
            .identity = .product,
            .record = record,
            .delay_shift_s = shift,
            .phase_centre = centre,
        };
    }

    const scale = b.plan.scales.get(sat.system);
    return .{
        .sat = sat,
        .source = switch (record) {
            .kepler => |e| .{ .kepler = .{
                .orbit = kepler.Orbit.fromEphemeris(e.record),
                .clock = onScale(e.record.clock(), scale),
            } },
            .glonass => |g| .{ .glonass = .{
                .orbit = glonass.Orbit.fromEphemeris(g),
                .clock = onScale(g.clock(), scale),
            } },
        },
        .identity = .{ .record = ref },
        .record = record,
        .phase_centre = centre,
    };
}

fn onScale(record_clock: clock.Poly, scale: ?clock.Poly) clock.Poly {
    return if (scale) |s| record_clock.plus(s) else record_clock;
}

pub fn keplerAt(b: *const bundle.Bundle, sat: types.SatId, t: GpsTime) ?gnss.reference.Kepler {
    const binding = b.plan.bindingAt(sat, t) orelse return null;
    return binding.kepler(&b.navigation);
}

pub fn glonassAt(b: *const bundle.Bundle, sat: types.SatId, t: GpsTime) ?*const records.GlonassEphemeris {
    const ref = b.plan.recordAt(sat, t) orelse return null;
    return switch (ref) {
        .glonass => |i| &b.navigation.glonass[i],
        .kepler => null,
    };
}
