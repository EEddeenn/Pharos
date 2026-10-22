const linear = @import("base/math/linear");
const kepler = @import("domain/navigation/orbit/kepler");
const tables = @import("domain/messages/bds/d1d2/fields");
const Parameters = @import("domain/navigation/orbit/parameters").Parameters;

const GpsTime = @import("domain/time/gps").GpsTime;

pub const Interval = struct { first: GpsTime, last: GpsTime };

const half_update_ms: i64 = 1_800_000;
const sample_count = 61;
const iterations = 4;

const Element = struct { name: []const u8, step: f64 };
const n = elements.len;
const Vector = [n]f64;

pub fn fitted(e: *const Parameters, flight: Interval) ?Parameters {
    const orbit = kepler.Orbit.fromParameters(e);
    var out = e.*;
    out.toe = tables.floorTo8s(e.toe);
    out.toc = tables.floorTo8s(e.toc);
    const dtc = out.toc.secondsSince(e.toc);
    out.af0 = e.af0 + (e.af1 + e.af2 * dtc) * dtc;
    out.af1 = e.af1 + 2.0 * e.af2 * dtc;

    const dt = out.toe.secondsSince(e.toe);
    out.m0 = e.m0 + (orbit.n + 0.5 * e.delta_n_dot * dt) * dt;
    out.delta_n = e.delta_n + e.delta_n_dot * dt;
    out.i0 = e.i0 + e.idot * dt;
    out.omega0 = e.omega0 + e.omega_dot * dt;
    out.a_dot = 0;
    out.delta_n_dot = 0;

    const first = earlier(flight.first, out.toe.addMs(-half_update_ms));
    const span_s = later(flight.last, out.toe.addMs(half_update_ms)).secondsSince(first);
    var times: [sample_count]GpsTime = undefined;
    var goal: [sample_count][3]f64 = undefined;
    for (&times, &goal, 0..) |*t, *g, i| {
        t.* = first.addSeconds(span_s * @as(f64, @floatFromInt(i)) / (sample_count - 1));
        g.* = orbit.state(t.*).pos.toArray();
    }

    var x: Vector = undefined;
    inline for (elements, 0..) |element, k| x[k] = @field(out, element.name);

    for (0..iterations) |_| {
        var normal: [n][n]f64 = @splat(@splat(0));
        var rhs: [n][1]f64 = @splat(@splat(0));
        for (times, goal) |t, g| {
            const now = positionOf(&out, &x, t) orelse return null;
            var jacobian: [3][n]f64 = undefined;
            for (elements, 0..) |element, k| {
                var plus = x;
                var minus = x;
                plus[k] += element.step;
                minus[k] -= element.step;
                const p = positionOf(&out, &plus, t) orelse return null;
                const m = positionOf(&out, &minus, t) orelse return null;
                for (0..3) |row| jacobian[row][k] = (p[row] - m[row]) / (2 * element.step);
            }

            for (0..3) |row| {
                const residual = g[row] - now[row];
                for (0..n) |k| {
                    rhs[k][0] += jacobian[row][k] * residual;
                    for (0..n) |j| normal[k][j] += jacobian[row][k] * jacobian[row][j];
                }
            }
        }

        var scale: Vector = undefined;
        for (&scale, 0..) |*s, k| s.* = 1.0 / @sqrt(normal[k][k]);
        for (0..n) |k| {
            rhs[k][0] *= scale[k];
            for (0..n) |j| normal[k][j] *= scale[k] * scale[j];
        }

        const dx = linear.solve(n, 1, &normal, &rhs);
        for (&x, dx, scale) |*v, d, s| v.* += d[0] * s;
    }

    const result = withElements(&out, &x);
    return if (result.calculationMisfit() == null) result else null;
}

fn withElements(base: *const Parameters, x: *const Vector) Parameters {
    var e = base.*;
    inline for (elements, 0..) |element, k| @field(e, element.name) = x[k];
    return e;
}

fn positionOf(base: *const Parameters, x: *const Vector, t: GpsTime) ?[3]f64 {
    const e = withElements(base, x);
    if (e.calculationMisfit() != null) return null;
    return kepler.Orbit.fromParameters(&e).state(t).pos.toArray();
}

fn earlier(a: GpsTime, b: GpsTime) GpsTime {
    return if (a.lessThan(b)) a else b;
}

fn later(a: GpsTime, b: GpsTime) GpsTime {
    return if (a.lessThan(b)) b else a;
}
const elements = [_]Element{
    .{ .name = "sqrt_a", .step = 1e-4 },
    .{ .name = "ecc", .step = 1e-9 },
    .{ .name = "w", .step = 1e-9 },
    .{ .name = "delta_n", .step = 1e-13 },
    .{ .name = "m0", .step = 1e-9 },
    .{ .name = "omega0", .step = 1e-9 },
    .{ .name = "omega_dot", .step = 1e-13 },
    .{ .name = "i0", .step = 1e-9 },
    .{ .name = "idot", .step = 1e-13 },
    .{ .name = "cuc", .step = 1e-9 },
    .{ .name = "cus", .step = 1e-9 },
    .{ .name = "crc", .step = 1e-3 },
    .{ .name = "crs", .step = 1e-3 },
    .{ .name = "cic", .step = 1e-9 },
    .{ .name = "cis", .step = 1e-9 },
};
