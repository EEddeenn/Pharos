const std = @import("std");

pub const V4 = @Vector(4, f32);
pub const V4u = @Vector(4, u32);
const V4i = @Vector(4, i32);

const SinCos = struct { s: V4, c: V4 };

inline fn sincosQuarter(x: V4) SinCos {
    const x2 = x * x;
    var p: V4 = @splat(1.0 / 6227020800.0);
    p = @mulAdd(V4, p, x2, @splat(-1.0 / 39916800.0));
    p = @mulAdd(V4, p, x2, @splat(1.0 / 362880.0));
    p = @mulAdd(V4, p, x2, @splat(-1.0 / 5040.0));
    p = @mulAdd(V4, p, x2, @splat(1.0 / 120.0));
    p = @mulAdd(V4, p, x2, @splat(-1.0 / 6.0));
    p = @mulAdd(V4, p, x2, @splat(1.0));
    const s = x * p;
    var q: V4 = @splat(1.0 / 479001600.0);
    q = @mulAdd(V4, q, x2, @splat(-1.0 / 3628800.0));
    q = @mulAdd(V4, q, x2, @splat(1.0 / 40320.0));
    q = @mulAdd(V4, q, x2, @splat(-1.0 / 720.0));
    q = @mulAdd(V4, q, x2, @splat(1.0 / 24.0));
    q = @mulAdd(V4, q, x2, @splat(-0.5));
    const c = @mulAdd(V4, q, x2, @splat(1.0));
    return .{ .s = s, .c = c };
}

pub inline fn sincosTurn(phase: V4u) SinCos {
    const quad = phase >> @splat(30);
    const frac_bits = phase & @as(V4u, @splat(0x3fffffff));
    const t: V4 = @as(V4, @floatFromInt(frac_bits)) * @as(V4, @splat(1.0 / 1073741824.0));
    const qs = sincosQuarter(t * @as(V4, @splat(std.math.pi / 2.0)));
    const odd = (quad & @as(V4u, @splat(1))) == @as(V4u, @splat(1));
    const c1 = @select(f32, odd, qs.s, qs.c);
    const s1 = @select(f32, odd, qs.c, qs.s);
    const neg_c = (quad -% @as(V4u, @splat(1))) < @as(V4u, @splat(2));
    const neg_s = quad >= @as(V4u, @splat(2));
    return .{ .c = @select(f32, neg_c, -c1, c1), .s = @select(f32, neg_s, -s1, s1) };
}

const sqrt_half: f32 = 0.70710678118654752440;
const log_coefficients = [_]f32{ 7.0376836292e-2, -1.1514610310e-1, 1.1676998740e-1, -1.2420140846e-1, 1.4249322787e-1, -1.6668057665e-1, 2.0000714765e-1, -2.4999993993e-1, 3.3333331174e-1 };
const ln2_high: f32 = 0.693359375;
const ln2_low: f32 = -2.12194440e-4;

pub inline fn logf(x: V4) V4 {
    const bits: V4u = @bitCast(x);
    const exp_field: V4i = @bitCast(bits >> @splat(23));
    const mant_bits = (bits & @as(V4u, @splat(0x007fffff))) | @as(V4u, @splat(0x3f000000));
    const m: V4 = @bitCast(mant_bits);
    var e: V4 = @floatFromInt(exp_field - @as(V4i, @splat(126)));
    const one: V4 = @splat(1.0);
    const lt = m < @as(V4, @splat(sqrt_half));
    e = @select(f32, lt, e - one, e);
    const f = @select(f32, lt, m + m - one, m - one);
    const z = f * f;
    var y: V4 = @splat(log_coefficients[0]);
    inline for (log_coefficients[1..]) |c| y = @mulAdd(V4, y, f, @splat(c));
    y = y * f * z;
    y = @mulAdd(V4, e, @splat(ln2_low), y);
    y = @mulAdd(V4, z, @splat(-0.5), y);
    var r = f + y;
    r = @mulAdd(V4, e, @splat(ln2_high), r);
    return r;
}

const table_bits = 12;
const table_len = 1 << table_bits;

const turn_table: [table_len][2]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [table_len][2]f64 = undefined;
    for (&t, 0..) |*e, i| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / table_len;
        e.* = .{ @cos(a), @sin(a) };
    }
    break :blk t;
};

pub const SinCos64 = struct { c: f64, s: f64 };

pub fn sincos64(phi: f64) SinCos64 {
    const t = phi - @floor(phi);
    const u = t * table_len;
    const i: usize = @intFromFloat(@floor(u));
    const r = (u - @floor(u)) * (2.0 * std.math.pi / @as(f64, table_len));
    const r2 = r * r;
    const cr = 1.0 - r2 * (0.5 - r2 * (1.0 / 24.0 - r2 / 720.0));
    const sr = r * (1.0 - r2 * (1.0 / 6.0 - r2 * (1.0 / 120.0 - r2 / 5040.0)));
    const e = turn_table[i & (table_len - 1)];
    return .{ .c = e[0] * cr - e[1] * sr, .s = e[1] * cr + e[0] * sr };
}
