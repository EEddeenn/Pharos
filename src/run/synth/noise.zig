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

inline fn words(seed: u64, g: u64, comptime k: u64) V4u {
    const a = splitmix(seed, g * 6 + k);
    const b = splitmix(seed, g * 6 + k + 1);
    return .{ @truncate(a), @truncate(a >> 32), @truncate(b), @truncate(b >> 32) };
}

const Pair4 = struct { re: V4, im: V4 };

const ln_2_pow_64 = 64.0 * 0.69314718055994530942;

// The low words, at most 1 in all, move a lane's value only below 2^25, where the spacing of floats drops under 4.
const low_words_matter: V4 = @splat(33554432.0);

pub inline fn group(seed: u64, g: u64) Pair4 {
    const hi = words(seed, g, 0);
    const ang = words(seed, g, 4);
    const hi_f: V4 = @floatFromInt(hi);
    const value = if (@reduce(.Or, hi_f < low_words_matter)) blk: {
        const lo = words(seed, g, 2) | @as(V4u, @splat(1));
        break :blk @mulAdd(V4, @floatFromInt(lo), @splat(1.0 / 4294967296.0), hi_f);
    } else hi_f;
    const neg2ln = @max(@mulAdd(V4, trig.logf(value), @splat(-2.0), @splat(ln_2_pow_64)), @as(V4, @splat(0.0)));
    const r = @sqrt(neg2ln);
    const sc = trig.sincosTurn(ang);
    return .{ .re = r * sc.c, .im = r * sc.s };
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
