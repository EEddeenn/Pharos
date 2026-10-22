const std = @import("std");
const field = @import("base/binary/field");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const nequick_fields = @import("domain/messages/galileo/fields/ionosphere");
const bdgim_fields = @import("domain/messages/bds/fields/ionosphere");
const Klobuchar = @import("domain/propagation/ionosphere/klobuchar").Model;
const NeQuick = @import("domain/propagation/ionosphere/nequick").Coefficients;

pub fn klobuchar(source: Klobuchar) Klobuchar {
    const value = klobuchar_fields.Coefficients.of(source);
    const raw = field.project(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, &value);
    var out: Klobuchar = undefined;
    inline for (.{ "alpha0", "alpha1", "alpha2", "alpha3" }, 0..) |name, i| out.alpha[i] = field.value(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, name, raw);
    inline for (.{ "beta0", "beta1", "beta2", "beta3" }, 0..) |name, i| out.beta[i] = field.value(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, name, raw);
    return out;
}

pub fn nequick(source: NeQuick) NeQuick {
    const raw = field.project(NeQuick, &nequick_fields.rows, &source);
    return .{ .ai0 = field.value(NeQuick, &nequick_fields.rows, "ai0", raw), .ai1 = field.value(NeQuick, &nequick_fields.rows, "ai1", raw), .ai2 = field.value(NeQuick, &nequick_fields.rows, "ai2", raw) };
}

pub fn bdgim(source: [9]f64) [9]f64 {
    const raw = field.project([9]f64, &bdgim_fields.bdgim, &source);
    var out: [9]f64 = undefined;
    inline for (0..9) |i| {
        const name = comptime std.fmt.comptimePrint("bdgim_alpha{d}", .{i + 1});
        const value = field.value([9]f64, &bdgim_fields.bdgim, name, raw);
        out[i] = if (i == 4) -value else value;
    }
    return out;
}
