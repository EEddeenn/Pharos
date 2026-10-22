const std = @import("std");
const manifest = @import("domain/propagation/troposphere/manifest");
const gpt3 = @import("domain/propagation/troposphere/gpt3");
const angles = @import("base/math/angles");

const Lla = @import("domain/earth/coordinates").Lla;

const height_correction_a = 2.53e-5;
const height_correction_b = 5.49e-3;
const height_correction_c = 1.14e-3;

const degree = 12;
const term_count = (degree + 1) * (degree + 2) / 2;

const expansions: [8][term_count][5]f64 = blk: {
    @setEvalBranchQuota(8 * term_count * 5 * 4);
    const blob = manifest.vmf3_bc.bytes;
    std.debug.assert(blob.len == 8 * term_count * 5 * 8);
    var out: [8][term_count][5]f64 = undefined;
    for (0..8) |a| {
        for (0..term_count) |i| {
            for (0..5) |s| {
                const at = ((a * term_count + i) * 5 + s) * 8;
                out[a][i][s] = @bitCast(std.mem.readInt(u64, blob[at..][0..8], .little));
            }
        }
    }
    break :blk out;
};

const Mapping = struct { hydrostatic: f64, wet: f64 };

const Fraction = struct { a: f64, b: f64, c: f64 };

pub const MappingCoefficients = struct {
    hydrostatic: Fraction,
    wet: Fraction,
};

pub fn coefficients(doy: f64, rx: Lla, ah: f64, aw: f64) MappingCoefficients {
    const pi = angles.pi;
    const pol_dist = pi / 2 - rx.lat_rad;
    const x = @sin(pol_dist) * @cos(rx.lon_rad);
    const y = @sin(pol_dist) * @sin(rx.lon_rad);
    const z = @cos(pol_dist);
    var v: [degree + 1][degree + 1]f64 = undefined;
    var w: [degree + 1][degree + 1]f64 = undefined;
    v[0][0] = 1;
    w[0][0] = 0;
    v[1][0] = z * v[0][0];
    w[1][0] = 0;
    for (2..degree + 1) |n| {
        const nf: f64 = @floatFromInt(n);
        v[n][0] = ((2 * nf - 1) * z * v[n - 1][0] - (nf - 1) * v[n - 2][0]) / nf;
        w[n][0] = 0;
    }
    for (1..degree + 1) |m| {
        const mf: f64 = @floatFromInt(m);
        v[m][m] = (2 * mf - 1) * (x * v[m - 1][m - 1] - y * w[m - 1][m - 1]);
        w[m][m] = (2 * mf - 1) * (x * w[m - 1][m - 1] + y * v[m - 1][m - 1]);
        if (m < degree) {
            v[m + 1][m] = (2 * mf + 1) * z * v[m][m];
            w[m + 1][m] = (2 * mf + 1) * z * w[m][m];
        }
        var n = m + 2;
        while (n <= degree) : (n += 1) {
            const nf: f64 = @floatFromInt(n);
            v[n][m] = ((2 * nf - 1) * z * v[n - 1][m] - (nf + mf - 1) * v[n - 2][m]) / (nf - mf);
            w[n][m] = ((2 * nf - 1) * z * w[n - 1][m] - (nf + mf - 1) * w[n - 2][m]) / (nf - mf);
        }
    }
    var sums: [4][5]f64 = @splat(@splat(0));
    var i: usize = 0;
    for (0..degree + 1) |n| {
        for (0..n + 1) |m| {
            for (0..4) |c| {
                for (0..5) |s| sums[c][s] = sums[c][s] + (expansions[c][i][s] * v[n][m] + expansions[4 + c][i][s] * w[n][m]);
            }
            i += 1;
        }
    }
    const annual = doy / gpt3.days_per_year * 2 * pi;
    const semiannual = doy / gpt3.days_per_year * 4 * pi;
    var bc: [4]f64 = undefined;
    for (&bc, sums) |*coefficient, sum| {
        coefficient.* = sum[0] + sum[1] * @cos(annual) + sum[2] * @sin(annual) + sum[3] * @cos(semiannual) + sum[4] * @sin(semiannual);
    }
    return .{ .hydrostatic = .{ .a = ah, .b = bc[0], .c = bc[2] }, .wet = .{ .a = aw, .b = bc[1], .c = bc[3] } };
}

pub fn map(coefficients_: MappingCoefficients, el_rad: f64, height_m: f64) Mapping {
    const sin_el = @sin(el_rad);
    const hydrostatic = fraction(coefficients_.hydrostatic, sin_el);
    const correction = 1 / sin_el - fraction(.{ .a = height_correction_a, .b = height_correction_b, .c = height_correction_c }, sin_el);
    return .{
        .hydrostatic = hydrostatic + correction * height_m / 1000,
        .wet = fraction(coefficients_.wet, sin_el),
    };
}

fn fraction(coefficients_: Fraction, sin_el: f64) f64 {
    const a = coefficients_.a;
    const b = coefficients_.b;
    const c = coefficients_.c;
    return (1 + (a / (1 + b / (1 + c)))) / (sin_el + (a / (sin_el + b / (sin_el + c))));
}
