const core = @import("../core.zig");
const elements = core.elements;
const GpsTime = core.time.GpsTime;
const kepler = @import("kepler.zig");
const constants = @import("constants.zig");
const records = @import("records.zig");
const KeplerEphemeris = records.KeplerEphemeris;
const KeplerAlmanac = records.KeplerAlmanac;

pub fn fromEphemeris(eph: *const KeplerEphemeris, toa: GpsTime) ?KeplerAlmanac {
    const system = eph.system();
    const consts = constants.get(system);
    const n = @sqrt(consts.mu) / (eph.sqrt_a * eph.sqrt_a * eph.sqrt_a) + eph.delta_n;
    const dt = toa.secondsSince(eph.toe);
    const clock = eph.clock();
    var alm: KeplerAlmanac = .{
        .sat = eph.sat,
        .toa = toa,
        .health = eph.extra.almanacHealth(),
        .iod = @intCast(eph.iode & 0xFF),
        .carriers = switch (eph.extra) {
            .cnav => |x| x.carrierHealth(),
            else => null,
        },
        .ecc = eph.ecc,
        .sqrt_a = eph.sqrt_a,
        .omega0 = eph.omega0,
        .i0 = eph.i0,
        .w = eph.w,
        .omega_dot = eph.omega_dot,
        .m0 = eph.m0,
        .af0 = clock.bias(toa),
        .af1 = clock.drift(toa),
    };
    const orbit = kepler.Orbit.fromEphemeris(eph);
    if (orbit.geo) {
        const s = orbit.state(eph.toe);
        const el = elements.fromState(s.pos, elements.inertial(s.vel, s.pos, consts.omega_e), consts.mu) orelse return null;
        const toe_s = eph.toe.inScale(eph.weekScale()).asF64Seconds();
        alm.sqrt_a = @sqrt(el.a);
        alm.ecc = el.ecc;
        alm.i0 = el.i;
        alm.omega0 = el.node + consts.omega_e * toe_s;
        alm.m0 = el.e_anomaly - el.ecc * @sin(el.e_anomaly);
        alm.w = elements.normAngle(el.arg_lat - el.true_anomaly);
    }
    const weeks: f64 = @floatFromInt(toa.inScale(eph.weekScale()).period - eph.toe.inScale(eph.weekScale()).period);
    alm.m0 = elements.normAngle(alm.m0 + n * dt);
    alm.omega0 = elements.normAngle(alm.omega0 + eph.omega_dot * dt - consts.omega_e * weeks * core.time.s_per_week);
    alm.i0 += eph.idot * dt;
    return alm;
}
