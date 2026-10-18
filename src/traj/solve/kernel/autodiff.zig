const std = @import("std");

pub const width = @min(std.simd.suggestVectorLength(f64) orelse 1, 4);
const Derivatives = @Vector(width, f64);

pub const Dual = struct {
    pub const lanes = 32;
    value: f64,
    derivatives: [lanes]f64,

    pub fn constant(value: f64) Dual {
        return .{ .value = value, .derivatives = @splat(0) };
    }

    pub fn variable(value: f64, index: usize) Dual {
        var result = constant(value);
        result.derivatives[index] = 1;
        return result;
    }

    pub fn add(a: Dual, b: Dual) Dual {
        var result: Dual = .{ .value = a.value + b.value, .derivatives = undefined };
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const da: Derivatives = a.derivatives[i..][0..width].*;
            const db: Derivatives = b.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = da + db;
        }
        return result;
    }

    pub fn sub(a: Dual, b: Dual) Dual {
        var result: Dual = .{ .value = a.value - b.value, .derivatives = undefined };
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const da: Derivatives = a.derivatives[i..][0..width].*;
            const db: Derivatives = b.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = da - db;
        }
        return result;
    }

    pub fn mul(a: Dual, b: Dual) Dual {
        var result: Dual = .{ .value = a.value * b.value, .derivatives = undefined };
        const av: Derivatives = @splat(a.value);
        const bv: Derivatives = @splat(b.value);
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const da: Derivatives = a.derivatives[i..][0..width].*;
            const db: Derivatives = b.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = da * bv + av * db;
        }
        return result;
    }

    pub fn div(a: Dual, b: Dual) Dual {
        const value = a.value / b.value;
        var result: Dual = .{ .value = value, .derivatives = undefined };
        const value_vector: Derivatives = @splat(value);
        const bv: Derivatives = @splat(b.value);
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const da: Derivatives = a.derivatives[i..][0..width].*;
            const db: Derivatives = b.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = da / bv - value_vector * (db / bv);
        }
        return result;
    }

    pub fn neg(a: Dual) Dual {
        return a.scale(-1);
    }

    pub fn scale(a: Dual, factor: f64) Dual {
        var result: Dual = .{ .value = a.value * factor, .derivatives = undefined };
        const factor_vector: Derivatives = @splat(factor);
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const derivatives: Derivatives = a.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = derivatives * factor_vector;
        }
        return result;
    }

    pub fn sqrt(a: Dual) Dual {
        const value = @sqrt(a.value);
        return a.unary(value, 0.5 / value);
    }

    pub fn sinCos(a: Dual) struct { sine: Dual, cosine: Dual } {
        const sine = @sin(a.value);
        const cosine = @cos(a.value);
        return .{ .sine = a.unary(sine, cosine), .cosine = a.unary(cosine, -sine) };
    }

    pub fn atan2(y: Dual, x: Dual) Dual {
        const magnitude = @max(@abs(x.value), @abs(y.value));
        const xs = x.value / magnitude;
        const ys = y.value / magnitude;
        const denominator = xs * xs + ys * ys;
        var result: Dual = .{ .value = std.math.atan2(y.value, x.value), .derivatives = undefined };
        const xv: Derivatives = @splat(xs);
        const yv: Derivatives = @splat(ys);
        const denominator_vector: Derivatives = @splat(denominator);
        const magnitude_vector: Derivatives = @splat(magnitude);
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const dy: Derivatives = y.derivatives[i..][0..width].*;
            const dx: Derivatives = x.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = (xv * dy - yv * dx) / denominator_vector / magnitude_vector;
        }
        return result;
    }

    pub fn pow(a: Dual, exponent: f64) Dual {
        if (exponent == 0) return constant(1);
        if (exponent == 1) return a;
        return a.unary(std.math.pow(f64, a.value, exponent), exponent * std.math.pow(f64, a.value, exponent - 1));
    }

    pub fn log(a: Dual) Dual {
        return a.unary(@log(a.value), 1 / a.value);
    }

    pub fn isFinite(a: Dual) bool {
        if (!std.math.isFinite(a.value)) return false;
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const derivatives: Derivatives = a.derivatives[i..][0..width].*;
            const limit: Derivatives = @splat(std.math.inf(f64));
            if (!@reduce(.And, @abs(derivatives) < limit)) return false;
        }
        return true;
    }

    fn unary(a: Dual, value: f64, slope: f64) Dual {
        var result: Dual = .{ .value = value, .derivatives = undefined };
        const slope_vector: Derivatives = @splat(slope);
        inline for (0..lanes / width) |chunk| {
            const i = chunk * width;
            const derivatives: Derivatives = a.derivatives[i..][0..width].*;
            result.derivatives[i..][0..width].* = derivatives * slope_vector;
        }
        return result;
    }
};
