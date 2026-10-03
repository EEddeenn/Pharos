const std = @import("std");
const trig = @import("trig.zig");

const V4 = trig.V4;

pub const reseed_len: u32 = 512;

pub const chains = 4;
pub const lanes = @typeInfo(V4).vector.len;

pub const stride: u32 = chains * lanes;

pub const Rotor = struct {
    c_re: [chains]V4,
    c_im: [chains]V4,
    w_re: V4,
    w_im: V4,
    pw: [stride]trig.SinCos64,
    phase0: f64,
    step: f64,

    pub fn init(phase0: f64, step: f64, n0: u32) Rotor {
        std.debug.assert(n0 % stride == 0);
        var r: Rotor = undefined;
        r.phase0 = phase0;
        r.step = step;
        const w1 = trig.sincos64(step);
        r.pw[0] = .{ .c = 1.0, .s = 0.0 };
        for (1..stride) |l| {
            const a = r.pw[l - 1];
            r.pw[l] = .{ .c = a.c * w1.c - a.s * w1.s, .s = a.c * w1.s + a.s * w1.c };
        }
        const w_stride = trig.sincos64(stride * step);
        r.w_re = @splat(@floatCast(w_stride.c));
        r.w_im = @splat(@floatCast(w_stride.s));
        const grid = n0 - n0 % reseed_len;
        r.seed(grid);
        var n = grid;
        while (n < n0) : (n += stride) r.advance();
        return r;
    }

    pub fn seed(r: *Rotor, n: u32) void {
        const c0 = trig.sincos64(r.phase0 + @as(f64, @floatFromInt(n)) * r.step);
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
