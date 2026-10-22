const std = @import("std");
const physical = @import("domain/physical_constants");
const field = @import("base/binary/field");
const elements = @import("domain/navigation/orbit/elements");
const time = @import("domain/time/gps");
const kepler = @import("domain/navigation/orbit/kepler");
const nominal = @import("domain/navigation/orbit/constants/galileo");
const schedule = @import("domain/messages/galileo/inav/schedule");
const Word = @import("domain/messages/galileo/inav/page").Word;
const GpsTime = time.GpsTime;
const Ephemeris = @import("domain/messages/galileo/inav/content").Parameters;
const constants = nominal.orbit;
const duration_s = 600.0;
const subframe_ms = 30_000;
const sisa_unusable_index = 126;
const Parameters = struct {
    delta_a: f64,
    ex: f64,
    ey: f64,
    delta_i: f64,
    omega0: f64,
    lambda0: f64,
    af0: f64,
    af1: f64,
};

const P = field.Field(Parameters);
const rows = [_]P{
    .{ .name = "type", .width = 6, .src = .{ .constant = 16 } },
    .{ .name = "delta_a", .width = 5, .repr = .twos, .scale_log2 = 8, .src = .{ .field = "delta_a" } },
    .{ .name = "ex", .width = 13, .repr = .twos, .scale_log2 = -22, .src = .{ .field = "ex" } },
    .{ .name = "ey", .width = 13, .repr = .twos, .scale_log2 = -22, .src = .{ .field = "ey" } },
    .{ .name = "delta_i", .width = 17, .repr = .twos, .scale_log2 = -22, .semicircles = true, .src = .{ .field = "delta_i" } },
    .{ .name = "omega0", .width = 23, .repr = .twos, .scale_log2 = -22, .semicircles = true, .periodic = true, .src = .{ .field = "omega0" } },
    .{ .name = "lambda0", .width = 23, .repr = .twos, .scale_log2 = -22, .semicircles = true, .periodic = true, .src = .{ .field = "lambda0" } },
    .{ .name = "af0", .width = 22, .repr = .twos, .scale_log2 = -26, .src = .{ .field = "af0" } },
    .{ .name = "af1", .width = 6, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "af1" } },
};

pub fn build(eph: *const Ephemeris, transmitted: GpsTime) ?Word {
    if (eph.e1b_hs != 0 or eph.e1b_dvs or eph.e5b_hs != 0 or eph.e5b_dvs) return null;
    if (eph.sisa_index >= sisa_unusable_index) return null;
    const reference = referenceTime(transmitted);
    const source = kepler.Orbit.fromParameters(&eph.eph);
    const state = source.state(reference);
    const el = elements.fromState(state.pos, elements.inertial(state.vel, state.pos, constants.omega_e), constants.mu) orelse return null;
    const w = elements.normAngle(el.arg_lat - el.true_anomaly);
    const p: Parameters = .{
        .delta_a = el.a - nominal.a_ref,
        .ex = el.ecc * @cos(w),
        .ey = el.ecc * @sin(w),
        .delta_i = el.i - nominal.nominal_i0,
        .omega0 = angleOnGrid(el.node + constants.omega_e * reference.sow()),
        .lambda0 = angleOnGrid(el.e_anomaly - el.ecc * @sin(el.e_anomaly) + w),
        .af0 = 0,
        .af1 = 0,
    };
    const orbital_word = encode(&p) catch return null;
    var quantized = parametersOf(&orbital_word);
    const reduced = orbitOf(&quantized, reference);

    quantized.af0 = clockAt(eph, &source, &reduced, reference);
    const end_bias = clockAt(eph, &source, &reduced, reference.addSeconds(duration_s));
    quantized.af1 = (end_bias - quantized.af0) / duration_s;
    return encode(&quantized) catch null;
}

fn encode(p: *const Parameters) field.Error!Word {
    var out: Word = .{};
    var w = out.writer();
    try field.encode(Parameters, &rows, p, .{}, &w);
    return out;
}

fn referenceTime(transmitted: GpsTime) GpsTime {
    return .{ .ms = @divFloor(transmitted.ms, subframe_ms) * subframe_ms + schedule.offset_ms, .sub_ms = 0 };
}

fn angleOnGrid(angle: f64) f64 {
    const lsb = std.math.pi * 0x1p-22;
    return elements.normAngle(@round(elements.normAngle(angle) / lsb) * lsb);
}

fn parametersOf(word: *const Word) Parameters {
    const raw = field.decode(Parameters, &rows, &word.words);
    var p: Parameters = undefined;
    inline for (@typeInfo(Parameters).@"struct".field_names) |name| @field(p, name) = field.value(Parameters, &rows, name, raw);
    return p;
}

fn orbitOf(p: *const Parameters, reference: GpsTime) kepler.Orbit {
    const a = nominal.a_ref + p.delta_a;
    const e = std.math.hypot(p.ex, p.ey);
    const w = std.math.atan2(p.ey, p.ex);
    return .{
        .toe = reference,
        .toe_sow = reference.sow(),
        .mu = constants.mu,
        .omega_e = constants.omega_e,
        .geo = false,
        .a = a,
        .a_dot = 0,
        .n = @sqrt(constants.mu / (a * a * a)),
        .delta_n_dot = 0,
        .e = e,
        .root_1me2 = @sqrt(1.0 - e * e),
        .m0 = p.lambda0 - w,
        .w = w,
        .omega0 = p.omega0,
        .omega_dot = 0,
        .i0 = nominal.nominal_i0 + p.delta_i,
        .idot = 0,
        .cuc = 0,
        .cus = 0,
        .crc = 0,
        .crs = 0,
        .cic = 0,
        .cis = 0,
    };
}

fn clockAt(eph: *const Ephemeris, source: *const kepler.Orbit, reduced: *const kepler.Orbit, t: GpsTime) f64 {
    const full = source.state(t);
    const red = reduced.state(t);
    const radial = red.pos.sub(full.pos).dot(full.pos) / full.pos.norm();
    return eph.eph.clock().bias(t) + full.rel_s - red.rel_s + radial / physical.light_speed;
}

comptime {
    std.debug.assert(field.totalWidth(Parameters, &rows) == 128);
}
