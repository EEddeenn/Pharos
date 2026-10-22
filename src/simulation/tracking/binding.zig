const std = @import("std");
const flight = @import("simulation/model/flight_plan");
const antenna = @import("domain/navigation/antenna/phase_centre");
const gnss_types = @import("domain/gnss_types");
const kepler = @import("domain/navigation/orbit/kepler");
const glonass = @import("domain/navigation/orbit/glonass");
const clock = @import("domain/time/clock");
const precise = @import("domain/navigation/precise/product");

const GpsTime = @import("domain/time/gps").GpsTime;

pub const Source = union(enum) {
    kepler: struct { orbit: kepler.Orbit, clock: clock.Poly },
    glonass: struct { orbit: glonass.Orbit, clock: clock.Poly },
    precise: precise.Handle,
};

pub const ResolvedBinding = struct {
    leg: flight.LegId,
    binding: *const flight.Binding,
    source: Source,
    phase_centre: ?antenna.PhaseCentre,

    pub fn sameSource(self: ResolvedBinding, other: ResolvedBinding) bool {
        if (self.source == .precise or other.source == .precise) return self.source == .precise and other.source == .precise;
        return std.meta.eql(self.binding.reference, other.binding.reference);
    }

    pub fn delayShift(self: ResolvedBinding) f64 {
        return switch (self.binding.flown) {
            .precise => |p| p.delay_shift_s,
            .kepler, .glonass => 0,
        };
    }
};

pub const Inputs = struct {
    flight_plan: *const flight.FlightPlan,
    precise: ?*const precise.Product,
    phase_centres: *const antenna.PhaseCentres,
};

pub const Span = struct { from: GpsTime, until: GpsTime };

pub fn resolve(input: Inputs, sat: gnss_types.SatId, t: GpsTime, span: Span) ?ResolvedBinding {
    const leg = input.flight_plan.legIdAt(sat, t) orelse return null;
    const binding = if (input.flight_plan.timelines[flight.slot(sat)].legs[leg.index].binding) |*value| value else return null;
    const centre = input.phase_centres.at(sat, t);
    const scale = input.flight_plan.scales.get(sat.system);
    var out: ResolvedBinding = .{
        .leg = leg,
        .binding = binding,
        .source = undefined,
        .phase_centre = centre,
    };
    switch (binding.flown) {
        .kepler => |*p| out.source = .{ .kepler = .{ .orbit = kepler.Orbit.fromParameters(p), .clock = onScale(p.clock(), scale) } },
        .glonass => |*g| {
            out.source = .{ .glonass = .{
                .orbit = glonass.Orbit.fromState(g.tb, .{ .pos = .fromArray(g.pos), .vel = .fromArray(g.vel) }, g.acc),
                .clock = onScale(g.clock, scale),
            } };
        },
        .precise => {
            out.source = .{ .precise = input.precise.?.handle(sat, span.from, span.until, if (centre) |c| .{ .body_m = c.reference_m, .law = c.law } else null) orelse return null };
        },
    }
    return out;
}

fn onScale(record_clock: clock.Poly, scale: ?clock.Poly) clock.Poly {
    return if (scale) |s| record_clock.plus(s) else record_clock;
}
