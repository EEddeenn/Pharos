const std = @import("std");

const V4 = @Vector(4, f32);

pub const reseed_len: u32 = 512;

pub const chains = 4;
pub const lanes = @typeInfo(V4).vector.len;

pub const stride: u32 = chains * lanes;

pub const Rotor = struct {
    c_re: [chains]V4,
    c_im: [chains]V4,
    w_re: V4,
    w_im: V4,
    pw: [stride]SinCos64,
    phase0: f64,
    step: f64,

    pub fn init(r: *Rotor, phase0: f64, step: f64, n0: u32) void {
        std.debug.assert(n0 % reseed_len == 0);
        r.phase0 = phase0;
        r.step = step;
        const w1 = sincos64(step);
        r.pw[0] = .{ .c = 1.0, .s = 0.0 };
        for (1..stride) |l| {
            const a = r.pw[l - 1];
            r.pw[l] = .{ .c = a.c * w1.c - a.s * w1.s, .s = a.c * w1.s + a.s * w1.c };
        }
        const w_stride = sincos64(stride * step);
        r.w_re = @splat(@floatCast(w_stride.c));
        r.w_im = @splat(@floatCast(w_stride.s));
        r.seed(n0);
    }

    pub fn seed(r: *Rotor, n: u32) void {
        const c0 = sincos64(r.phase0 + @as(f64, @floatFromInt(n)) * r.step);
        var cr: [stride]f32 = undefined;
        var ci: [stride]f32 = undefined;
        for (0..stride) |l| {
            const p = r.pw[l];
            cr[l] = @floatCast(c0.c * p.c - c0.s * p.s);
            ci[l] = @floatCast(c0.c * p.s + c0.s * p.c);
        }
        inline for (0..chains) |q| {
            r.c_re[q] = cr[lanes * q ..][0..lanes].*;
            r.c_im[q] = ci[lanes * q ..][0..lanes].*;
        }
    }

    pub inline fn advance(r: *Rotor) void {
        inline for (0..chains) |q| {
            const t = @mulAdd(V4, r.c_re[q], r.w_re, -r.c_im[q] * r.w_im);
            r.c_im[q] = @mulAdd(V4, r.c_re[q], r.w_im, r.c_im[q] * r.w_re);
            r.c_re[q] = t;
        }
    }
};

const table_bits = 12;
const table_len = 1 << table_bits;

const turn_table: [table_len]SinCos64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [table_len]SinCos64 = undefined;
    for (&t, 0..) |*e, i| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / table_len;
        e.* = .{ .c = @cos(a), .s = @sin(a) };
    }
    break :blk t;
};

const SinCos64 = struct { c: f64, s: f64 };

fn sincos64(phi: f64) SinCos64 {
    const t = phi - @floor(phi);
    const u = t * table_len;
    const i: usize = @intFromFloat(@floor(u));
    const r = (u - @floor(u)) * (2.0 * std.math.pi / @as(f64, table_len));
    const r2 = r * r;
    const cr = 1.0 - r2 * (0.5 - r2 * (1.0 / 24.0 - r2 / 720.0));
    const sr = r * (1.0 - r2 * (1.0 / 6.0 - r2 * (1.0 / 120.0 - r2 / 5040.0)));
    const e = turn_table[i & (table_len - 1)];
    return .{ .c = e.c * cr - e.s * sr, .s = e.s * cr + e.c * sr };
}
