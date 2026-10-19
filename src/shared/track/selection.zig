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
};

const Identity = union(enum) { record: bundle.plan.Ref, product };

pub const Selection = struct {
    sat: types.SatId,
    source: Source,
    identity: Identity,
    record: Record,
    air: []const gnss.air.Row,
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
        const shift = clock_ref.offset(binding.air[gnss.spec.slot(pair[0])].delay_s.get(.data), binding.air[gnss.spec.slot(pair[1])].delay_s.get(.data));
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
            .air = binding.air,
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
        .air = binding.air,
        .phase_centre = centre,
    };
}

fn onScale(record_clock: clock.Poly, scale: ?clock.Poly) clock.Poly {
    return if (scale) |s| record_clock.plus(s) else record_clock;
}
