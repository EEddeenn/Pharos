const std = @import("std");

pub const Repr = enum { unsigned, twos, sign_mag };
pub const Error = error{ FieldOverflow, ValueMissing };

pub fn quantize(comptime width: u7, comptime repr: Repr, comptime scale_log2: i8, value: f64) error{FieldOverflow}!@Int(.unsigned, width) {
    const rounded = @round(std.math.ldexp(value, -@as(i32, scale_log2)));
    if (!std.math.isFinite(rounded) or @abs(rounded) >= 0x1p64) return error.FieldOverflow;
    return fromInt(width, repr, @intFromFloat(rounded));
}

pub fn roundWithin(x: f64, min: i64, max: i64) ?i64 {
    const q = @round(x);
    if (!std.math.isFinite(q) or q < -0x1p63 or q >= 0x1p63) return null;
    const value: i64 = @intFromFloat(q);
    return if (value < min or value > max) null else value;
}

pub fn quantizeAngle(comptime width: u7, comptime repr: Repr, semicircles: f64) error{FieldOverflow}!@Int(.unsigned, width) {
    comptime std.debug.assert(width >= 1 and width <= 64);
    if (!std.math.isFinite(semicircles)) return error.FieldOverflow;
    return angleCode(width, repr, semicircles);
}

/// Packs a finite angle already admitted by its producer.
pub fn angleCode(comptime width: u7, comptime repr: Repr, semicircles: f64) @Int(.unsigned, width) {
    comptime std.debug.assert(width >= 1 and width <= 64);
    const rounded = @round(std.math.ldexp(@rem(semicircles, 2.0), @as(i32, width) - 1));
    const half: i128 = @as(i128, 1) << (width - 1);
    var q: i128 = @intFromFloat(rounded);
    if (q < -half or q > half) q = @mod(q + half, 2 * half) - half;
    switch (repr) {
        .twos => {
            const signed: @Int(.signed, width) = @intCast(if (q == half) -half else q);
            return @bitCast(signed);
        },
        .sign_mag => {
            if (width < 2) @compileError("sign-magnitude fields need a sign bit and a magnitude");
            const bounded = std.math.clamp(q, 1 - half, half - 1);
            const magnitude: @Int(.unsigned, width - 1) = @intCast(@abs(bounded));
            return (@as(@Int(.unsigned, width), @intFromBool(bounded < 0)) << (width - 1)) | magnitude;
        },
        .unsigned => @compileError("an angle field is signed"),
    }
}

pub fn fromInt(comptime width: u7, comptime repr: Repr, value: i128) error{FieldOverflow}!@Int(.unsigned, width) {
    comptime std.debug.assert(width >= 1 and width <= 64);
    switch (repr) {
        .unsigned => return std.math.cast(@Int(.unsigned, width), value) orelse error.FieldOverflow,
        .twos => {
            const signed = std.math.cast(@Int(.signed, width), value) orelse return error.FieldOverflow;
            return @bitCast(signed);
        },
        .sign_mag => {
            if (width < 2) @compileError("sign-magnitude fields need a sign bit and a magnitude");
            const magnitude = std.math.cast(@Int(.unsigned, width - 1), @abs(value)) orelse return error.FieldOverflow;
            return (@as(@Int(.unsigned, width), @intFromBool(value < 0)) << (width - 1)) | magnitude;
        },
    }
}

pub fn dequantize(comptime width: u7, comptime repr: Repr, comptime scale_log2: i8, raw: @Int(.unsigned, width)) f64 {
    return std.math.ldexp(@as(f64, @floatFromInt(toInt(width, repr, raw))), scale_log2);
}

pub fn mask(width: u7) u64 {
    return if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn toInt(comptime width: u7, comptime repr: Repr, raw: @Int(.unsigned, width)) i128 {
    switch (repr) {
        .unsigned => return raw,
        .twos => return @as(@Int(.signed, width), @bitCast(raw)),
        .sign_mag => {
            const magnitude: i128 = @as(@Int(.unsigned, width - 1), @truncate(raw));
            return if (raw >> (width - 1) != 0) -magnitude else magnitude;
        },
    }
}
