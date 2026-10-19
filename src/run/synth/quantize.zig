const std = @import("std");
const IqFormat = @import("shared").core.types.IqFormat;

const V4 = @Vector(4, f32);
const V4u = @Vector(4, u32);
const V4i = @Vector(4, i32);

const iq8_scale: f32 = 25.0;
const iq16_scale: f32 = 3277.0;
const iq4_scale: f32 = 3.0;
const iq4_max = 7;
const iq2_threshold: f32 = 1.1;
const iq2_clip_ratio: f32 = 5.0;

fn vectorGranule(format: IqFormat) u32 {
    return switch (format) {
        .iq2 => 8,
        .iq4, .iq8, .iq16 => 4,
    };
}

fn scale(comptime T: type) f32 {
    return switch (T) {
        i8 => iq8_scale,
        i16 => iq16_scale,
        else => @compileError("IQ8 and IQ16 have i8 and i16 components"),
    };
}

inline fn count(mask: @Vector(4, bool)) V4u {
    return @intFromBool(mask);
}

fn vectorLinear(comptime T: type, re: []const f32, im: []const f32, gain: f32, out: []u8) u64 {
    const g: V4 = @splat(gain * scale(T));
    const lo: V4 = @splat(std.math.minInt(T));
    const hi: V4 = @splat(std.math.maxInt(T));
    const above: V4 = @splat(std.math.maxInt(T) + 1);
    const below: V4 = @splat(std.math.minInt(T) - 1);
    const n = 8 * @sizeOf(T);
    var clip: V4u = @splat(0);
    var i: usize = 0;
    while (i < re.len) : (i += 4) {
        const a = @as(V4, re[i..][0..4].*) * g;
        const b = @as(V4, im[i..][0..4].*) * g;
        clip += count(a >= above) + count(a <= below);
        clip += count(b >= above) + count(b <= below);
        const qa: V4i = @intFromFloat(@min(@max(a, lo), hi));
        const qb: V4i = @intFromFloat(@min(@max(b, lo), hi));
        const ia: @Vector(4, T) = @truncate(qa);
        const ib: @Vector(4, T) = @truncate(qb);
        const packed_v: @Vector(8, T) = std.simd.interlace(.{ ia, ib });
        out[i * 2 * @sizeOf(T) ..][0..n].* = @bitCast(packed_v);
    }
    return @reduce(.Add, clip);
}

fn vectorIq4(re: []const f32, im: []const f32, gain: f32, out: []u8) u64 {
    const g: V4 = @splat(gain * iq4_scale);
    const zero: V4 = @splat(0.0);
    const top: V4 = @splat(iq4_max);
    const above: V4 = @splat(iq4_max + 1);
    var clip: V4u = @splat(0);
    var i: usize = 0;
    while (i < re.len) : (i += 4) {
        const a: V4 = re[i..][0..4].*;
        const b: V4 = im[i..][0..4].*;
        const ma = @abs(a) * g;
        const mb = @abs(b) * g;
        clip += count(ma >= above) + count(mb >= above);
        var qa: V4u = @intFromFloat(@min(ma, top));
        var qb: V4u = @intFromFloat(@min(mb, top));
        qa |= @select(u32, a >= zero, @as(V4u, @splat(0)), @as(V4u, @splat(8)));
        qb |= @select(u32, b >= zero, @as(V4u, @splat(0)), @as(V4u, @splat(8)));
        const bytes: @Vector(4, u8) = @truncate((qa << @splat(4)) | qb);
        out[i..][0..4].* = @bitCast(bytes);
    }
    return @reduce(.Add, clip);
}

fn vectorIq2(re: []const f32, im: []const f32, gain: f32, out: []u8) u64 {
    const threshold: V4 = @splat(iq2_threshold / gain);
    const clip_threshold: V4 = @splat(iq2_clip_ratio * (iq2_threshold / gain));
    const zero: V4 = @splat(0.0);
    var clip: V4u = @splat(0);
    var i: usize = 0;
    var codes: [2]V4u = undefined;
    while (i < re.len) : (i += 8) {
        inline for (0..2) |h| {
            const a: V4 = re[i + 4 * h ..][0..4].*;
            const b: V4 = im[i + 4 * h ..][0..4].*;
            const va = @abs(a);
            const vb = @abs(b);
            clip += count(va >= clip_threshold) + count(vb >= clip_threshold);
            const fa = @select(u32, a < zero, @as(V4u, @splat(2)), @as(V4u, @splat(0))) | count(va >= threshold);
            const fb = @select(u32, b < zero, @as(V4u, @splat(2)), @as(V4u, @splat(0))) | count(vb >= threshold);
            codes[h] = fa | (fb << @splat(2));
        }
        const both = std.simd.join(codes[0], codes[1]);
        const parts = std.simd.deinterlace(2, both);
        const bytes: @Vector(4, u8) = @truncate(parts[0] | (parts[1] << @splat(4)));
        out[i / 2 ..][0..4].* = @bitCast(bytes);
    }
    return @reduce(.Add, clip);
}

fn vector(format: IqFormat, re: []const f32, im: []const f32, gain: f32, out: []u8) u64 {
    return switch (format) {
        .iq2 => vectorIq2(re, im, gain, out),
        .iq4 => vectorIq4(re, im, gain, out),
        .iq8 => vectorLinear(i8, re, im, gain, out),
        .iq16 => vectorLinear(i16, re, im, gain, out),
    };
}

pub fn pack(format: IqFormat, re: []const f32, im: []const f32, gain: f32, out: []u8) u64 {
    std.debug.assert(re.len == im.len);
    const len: u32 = @intCast(re.len);
    std.debug.assert(out.len >= format.bytesFor(len));
    const granule = vectorGranule(format);
    const head = len - len % granule;
    var clipped = vector(format, re[0..head], im[0..head], gain, out);
    if (head < len) {
        var tail_re: [8]f32 = @splat(0);
        var tail_im: [8]f32 = @splat(0);
        @memcpy(tail_re[0 .. len - head], re[head..]);
        @memcpy(tail_im[0 .. len - head], im[head..]);
        var bytes: [16]u8 = undefined;
        clipped += vector(format, tail_re[0..granule], tail_im[0..granule], gain, &bytes);
        const tail_bytes = format.bytesFor(len - head);
        @memcpy(out[format.bytesFor(head)..][0..tail_bytes], bytes[0..tail_bytes]);
    }
    return clipped;
}
