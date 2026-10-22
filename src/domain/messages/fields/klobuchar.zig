const std = @import("std");
const field = @import("base/binary/field");
const klobuchar = @import("domain/propagation/ionosphere/klobuchar");
pub const Coefficients = struct {
    alpha0: f64,
    alpha1: f64,
    alpha2: f64,
    alpha3: f64,
    beta0: f64,
    beta1: f64,
    beta2: f64,
    beta3: f64,

    pub fn of(m: klobuchar.Model) Coefficients {
        return .{
            .alpha0 = m.alpha[0],
            .alpha1 = m.alpha[1],
            .alpha2 = m.alpha[2],
            .alpha3 = m.alpha[3],
            .beta0 = m.beta[0],
            .beta1 = m.beta[1],
            .beta2 = m.beta[2],
            .beta3 = m.beta[3],
        };
    }
};

pub const coefficients = rows(Coefficients, "");
pub const Codes = field.Decoded(Coefficients, &coefficients);

pub fn rows(comptime Source: type, comptime prefix: []const u8) [8]field.Field(Source) {
    return .{
        .{ .name = "alpha0", .width = 8, .repr = .twos, .scale_log2 = -30, .src = .{ .field = path(prefix, "alpha0") } },
        .{ .name = "alpha1", .width = 8, .repr = .twos, .scale_log2 = -27, .src = .{ .field = path(prefix, "alpha1") } },
        .{ .name = "alpha2", .width = 8, .repr = .twos, .scale_log2 = -24, .src = .{ .field = path(prefix, "alpha2") } },
        .{ .name = "alpha3", .width = 8, .repr = .twos, .scale_log2 = -24, .src = .{ .field = path(prefix, "alpha3") } },
        .{ .name = "beta0", .width = 8, .repr = .twos, .scale_log2 = 11, .src = .{ .field = path(prefix, "beta0") } },
        .{ .name = "beta1", .width = 8, .repr = .twos, .scale_log2 = 14, .src = .{ .field = path(prefix, "beta1") } },
        .{ .name = "beta2", .width = 8, .repr = .twos, .scale_log2 = 16, .src = .{ .field = path(prefix, "beta2") } },
        .{ .name = "beta3", .width = 8, .repr = .twos, .scale_log2 = 16, .src = .{ .field = path(prefix, "beta3") } },
    };
}

fn path(comptime prefix: []const u8, comptime name: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ prefix, name });
}
