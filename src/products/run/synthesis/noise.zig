const std = @import("std");
const dictionary = @import("base/text/dictionary");

const V4 = @Vector(4, f32);
const V4u = @Vector(4, u32);
const V4i = @Vector(4, i32);

pub const Mode = enum(u32) {
    counter = 0,
    off = 1,

    pub const words = dictionary.tagNames(Mode);
};

const Pair4 = struct { re: V4, im: V4 };

const ln_2_pow_64 = 64.0 * std.math.ln2;

// A low word adds at most 1; that moves the rounded value only below 2^25, where floats are spaced under 4.
const low_words_matter: V4u = @splat(1 << 25);

const SinCos = struct { s: V4, c: V4 };

// Degree 3, fitted at Chebyshev nodes: error at most 1.3e-5.
const log_coefficients = [_]f32{ -1.4852839839e-01, 2.1452891615e-01, -2.5164769138e-01, 3.3314169743e-01 };
const ln2_high: f32 = 0.693359375;
const ln2_low: f32 = -2.12194440e-4;

const sqrt1_2_bits: V4u = @splat(@bitCast(@as(f32, std.math.sqrt1_2)));

pub inline fn group(seed: u64, g: u64) Pair4 {
    const hi = words(seed, g, 0);
    const ang = words(seed, g, 4);
    const hi_f: V4 = @floatFromInt(hi);
    const value = if (@reduce(.Or, hi < low_words_matter)) blk: {
        const lo = words(seed, g, 2) | @as(V4u, @splat(1));
        break :blk @mulAdd(V4, @floatFromInt(lo), @splat(0x1p-32), hi_f);
    } else hi_f;
    const neg2ln = @max(@mulAdd(V4, logf(value), @splat(-2.0), @splat(ln_2_pow_64)), @as(V4, @splat(0.0)));
    const r = @sqrt(neg2ln);
    const sc = sincosTurn(ang);
    return .{ .re = r * sc.c, .im = r * sc.s };
}

inline fn splitmix(seed: u64, c: u64) u64 {
    var z = seed +% c *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

inline fn words(seed: u64, g: u64, comptime k: u64) V4u {
    const a = splitmix(seed, g * 6 + k);
    const b = splitmix(seed, g * 6 + k + 1);
    return .{ @truncate(a), @truncate(a >> 32), @truncate(b), @truncate(b >> 32) };
}

// Degree 3 in x², fitted at Chebyshev nodes: errors at most 1.2e-6 (sin) and 6.8e-6 (cos).
inline fn sincosQuarter(x: V4) SinCos {
    const x2 = x * x;
    var p: V4 = @splat(-1.8522539325e-04);
    p = @mulAdd(V4, p, x2, @splat(8.3131914144e-03));
    p = @mulAdd(V4, p, x2, @splat(-1.6665676500e-01));
    p = @mulAdd(V4, p, x2, @splat(9.9999923706e-01));
    const s = x * p;
    var q: V4 = @splat(-1.2710112331e-03);
    q = @mulAdd(V4, q, x2, @splat(4.1487014140e-02));
    q = @mulAdd(V4, q, x2, @splat(-4.9991176041e-01));
    const c = @mulAdd(V4, q, x2, @splat(9.9999320210e-01));
    return .{ .s = s, .c = c };
}

inline fn sincosTurn(phase: V4u) SinCos {
    const frac_bits = phase & @as(V4u, @splat(0x3fffffff));
    const qs = sincosQuarter(@as(V4, @floatFromInt(frac_bits)) * @as(V4, @splat(std.math.pi / 2.0 * 0x1p-30)));
    const odd = (phase & @as(V4u, @splat(1 << 30))) != @as(V4u, @splat(0));
    const c1 = @select(f32, odd, qs.s, qs.c);
    const s1 = @select(f32, odd, qs.c, qs.s);
    // The quarter is the phase's top two bits: the sine is negative in the last two, the cosine in the middle two.
    const sign: V4u = @splat(1 << 31);
    const sign_c = (phase ^ (phase << @splat(1))) & sign;
    return .{ .c = @bitCast(@as(V4u, @bitCast(c1)) ^ sign_c), .s = @bitCast(@as(V4u, @bitCast(s1)) ^ (phase & sign)) };
}

inline fn logf(x: V4) V4 {
    // Less the bits of √½, x splits into 2^e times m in [√½, √2).
    const ix: V4i = @bitCast(@as(V4u, @bitCast(x)) -% sqrt1_2_bits);
    const e: V4 = @floatFromInt(ix >> @splat(23));
    const m: V4 = @bitCast((@as(V4u, @bitCast(ix)) & @as(V4u, @splat(0x007fffff))) +% sqrt1_2_bits);
    const f = m - @as(V4, @splat(1.0));
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
