const std = @import("std");
const core = @import("../../../core.zig");
const field = @import("../../../codec.zig").field;
const kepler = @import("../../kepler.zig");
const dc = @import("../dc.zig");

const GpsTime = core.time.GpsTime;
const Eph = @import("../../records.zig").KeplerEphemeris;
const Packet = dc.Packet;
const Correction = dc.Correction;
const P = field.Field(Packet);
const cdc = dc.cdc;
const edc = dc.edc;
const applied = dc.applied;

pub const Sample = struct { t: GpsTime, pos: [3]f64, clock_s: f64 };

fn rangeOf(comptime rows: []const P, comptime name: []const u8) f64 {
    const row = comptime field.rowOf(Packet, rows, name);
    const top = std.math.ldexp(@as(f64, 1 << (row.width - 1)) - 1, row.scale_log2);
    return if (row.semicircles) top * std.math.pi else top;
}

const ranges = [6]f64{ rangeOf(&edc, "alpha"), rangeOf(&edc, "beta"), rangeOf(&edc, "gamma"), rangeOf(&edc, "delta_i"), rangeOf(&edc, "delta_omega"), rangeOf(&edc, "delta_a") };
const steps = [6]f64{ 1e-9, 1e-9, 1e-9, 1e-9, 1e-9, 1e-2 };
const first_weight = 1e-4;
const last_weight = 10.0;

pub fn correction(record: *const Eph, t_od: GpsTime, samples: []const Sample) ?Correction {
    var weight: f64 = first_weight;
    const x = while (weight <= last_weight) : (weight *= 10) {
        const x = orbitFit(record, t_od, samples, weight) orelse return null;
        const p: Packet = .{ .corr = elements(x), .udra = 0, .udra_rate = 0 };
        if (field.fits(Packet, &edc, &p)) break x;
    } else return null;

    var out = elements(x);
    out.prn = record.sat.prn();

    var mean_t: f64 = 0;
    var mean_e: f64 = 0;
    for (samples) |s| {
        mean_t += s.t.secondsSince(record.toc);
        mean_e += s.clock_s;
    }
    const n: f64 = @floatFromInt(samples.len);
    mean_t /= n;
    mean_e /= n;

    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (samples) |s| {
        const dt = s.t.secondsSince(record.toc) - mean_t;
        sxx += dt * dt;
        sxy += dt * (s.clock_s - mean_e);
    }

    const limit = comptime rangeOf(&cdc, "af1");
    out.af1 = if (sxx > 0) std.math.clamp(sxy / sxx, -limit, limit) else 0;
    out.af0 = mean_e - out.af1 * mean_t;
    return out;
}

fn elements(x: [6]f64) Correction {
    return .{ .prn = 0, .alpha = x[0], .beta = x[1], .gamma = x[2], .delta_i = x[3], .delta_omega = x[4], .delta_a = x[5] };
}

fn orbitFit(record: *const Eph, t_od: GpsTime, samples: []const Sample, weight: f64) ?[6]f64 {
    var x: [6]f64 = @splat(0);
    for (0..4) |_| {
        var normal: [6][6]f64 = @splat(@splat(0));
        var rhs: [6][1]f64 = @splat(@splat(0));
        for (samples) |s| {
            const now = positionOf(record, x, t_od, s.t) orelse return null;
            var jacobian: [3][6]f64 = undefined;
            for (0..6) |k| {
                var plus = x;
                var minus = x;
                plus[k] += steps[k];
                minus[k] -= steps[k];
                const sp = positionOf(record, plus, t_od, s.t) orelse return null;
                const sm = positionOf(record, minus, t_od, s.t) orelse return null;
                for (0..3) |row| jacobian[row][k] = (sp[row] - sm[row]) / (2 * steps[k]);
            }

            for (0..3) |row| {
                const residual = s.pos[row] - now[row];
                for (0..6) |k| {
                    rhs[k][0] += jacobian[row][k] * residual;
                    for (0..6) |j| normal[k][j] += jacobian[row][k] * jacobian[row][j];
                }
            }
        }

        for (0..6) |k| {
            const w = weight / (ranges[k] * ranges[k]);
            normal[k][k] += w;
            rhs[k][0] -= w * x[k];
        }

        const dx = core.linear.solve(6, 1, 6, &normal, &rhs);
        for (0..6) |k| x[k] += dx[k][0];
    }
    for (x) |v| if (!std.math.isFinite(v)) return null;
    return x;
}

fn positionOf(record: *const Eph, x: [6]f64, t_od: GpsTime, t: GpsTime) ?[3]f64 {
    const e = applied(record, elements(x), t_od);
    if (e.misfit() != null) return null;
    return kepler.Orbit.fromParameters(&e).state(t).pos.toArray();
}
