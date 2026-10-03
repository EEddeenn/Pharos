const std = @import("std");
const dictionary = @import("shared").core.dictionary;
const Epoch = @import("shared").core.time.Epoch;
const trig = @import("trig.zig");

const V4 = trig.V4;
const V4u = trig.V4u;

pub const Mode = enum(u32) {
    counter = 0,
    off = 1,

    pub const words = dictionary.tagNames(Mode);
};

inline fn splitmix(seed: u64, c: u64) u64 {
    var z = seed +% c *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

const Uniforms = struct { hi: V4u, lo: V4u, ang: V4u };

inline fn groupUniforms(seed: u64, g: u64) Uniforms {
    var w: [12]u32 = undefined;
    inline for (0..6) |k| {
        const v = splitmix(seed, g * 6 + k);
        w[2 * k] = @truncate(v);
        w[2 * k + 1] = @truncate(v >> 32);
    }
    return .{ .hi = w[0..4].*, .lo = w[4..8].*, .ang = w[8..12].* };
}

const Pair4 = struct { re: V4, im: V4 };

const ln_2_pow_64 = 64.0 * 0.69314718055994530942;

inline fn boxMuller4(u: Uniforms) Pair4 {
    const lo = u.lo | @as(V4u, @splat(1));
    const value = @mulAdd(V4, @floatFromInt(lo), @splat(1.0 / 4294967296.0), @floatFromInt(u.hi));
    const neg2ln = @mulAdd(V4, trig.logf(value), @splat(-2.0), @splat(ln_2_pow_64));
    const r = @sqrt(neg2ln);
    const sc = trig.sincosTurn(u.ang);
    return .{ .re = r * sc.c, .im = r * sc.s };
}

inline fn group(seed: u64, g: u64) Pair4 {
    return boxMuller4(groupUniforms(seed, g));
}

fn counterFill(seed: u64, first: u64, re: []f32, im: []f32) void {
    std.debug.assert(re.len == im.len);
    var i: usize = 0;
    var idx = first;
    while (i < re.len and idx % 4 != 0) : ({
        i += 1;
        idx += 1;
    }) single(seed, idx, &re[i], &im[i]);
    while (i + 4 <= re.len) : ({
        i += 4;
        idx += 4;
    }) {
        const g = group(seed, idx / 4);
        re[i..][0..4].* = g.re;
        im[i..][0..4].* = g.im;
    }
    while (i < re.len) : ({
        i += 1;
        idx += 1;
    }) single(seed, idx, &re[i], &im[i]);
}

fn single(seed: u64, idx: u64, re: *f32, im: *f32) void {
    const g = group(seed, idx / 4);
    const ga: [4]f32 = g.re;
    const gb: [4]f32 = g.im;
    re.* = ga[idx % 4];
    im.* = gb[idx % 4];
}

pub fn fill(mode: Mode, seed: u64, epoch: Epoch, samples_per_epoch: u32, first: u32, re: []f32, im: []f32) void {
    switch (mode) {
        .counter => counterFill(seed, epoch.ms * samples_per_epoch + first, re, im),
        .off => {
            @memset(re, 0);
            @memset(im, 0);
        },
    }
}
