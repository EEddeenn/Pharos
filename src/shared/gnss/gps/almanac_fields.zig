const std = @import("std");
const constants = @import("constants.zig");
const field = @import("../../codec.zig").field;
const records = @import("../records.zig");

pub const Packet = records.KeplerAlmanac;
pub const Reference = @import("../almanac_reference.zig").Reference;
pub const reference = @import("../almanac_reference.zig").rows;

const P = field.Field(Packet);

pub fn reduced(comptime prn_width: u7) [5]P {
    return .{
        .{ .name = "prn", .width = prn_width, .src = .{ .computed_int = &prn } },
        .{ .name = "delta_a", .width = 8, .repr = .twos, .scale_log2 = 9, .src = .{ .computed = &deltaA } },
        .{ .name = "omega0", .width = 7, .repr = .twos, .scale_log2 = -6, .semicircles = true, .periodic = true, .src = .{ .field = "omega0" } },
        .{ .name = "phi0", .width = 7, .repr = .twos, .scale_log2 = -6, .semicircles = true, .periodic = true, .src = .{ .computed = &phi0 } },
        .{ .name = "health", .width = 3, .src = .{ .computed_int = &health } },
    };
}

pub fn midi(comptime prn_width: u7) [11]P {
    return .{
        .{ .name = "prna", .width = prn_width, .src = .{ .computed_int = &prn } },
        .{ .name = "health_a", .width = 3, .src = .{ .computed_int = &health } },
        .{ .name = "ecc", .width = 11, .scale_log2 = -16, .src = .{ .field = "ecc" } },
        .{ .name = "delta_i", .width = 11, .repr = .twos, .scale_log2 = -14, .semicircles = true, .src = .{ .computed = &deltaI } },
        .{ .name = "omega_dot", .width = 11, .repr = .twos, .scale_log2 = -33, .semicircles = true, .src = .{ .field = "omega_dot" } },
        .{ .name = "sqrt_a", .width = 17, .scale_log2 = -4, .src = .{ .field = "sqrt_a" } },
        .{ .name = "omega0", .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .field = "omega0" } },
        .{ .name = "w", .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .field = "w" } },
        .{ .name = "m0", .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .field = "m0" } },
        .{ .name = "af0_a", .width = 11, .repr = .twos, .scale_log2 = -20, .renamed = true, .src = .{ .field = "af0" } },
        .{ .name = "af1_a", .width = 10, .repr = .twos, .scale_log2 = -37, .renamed = true, .src = .{ .field = "af1" } },
    };
}

const max_ecc = 0.03;
const min_omega_dot_semicircles = -1.19e-7;

pub fn representable(a: records.KeplerAlmanac) bool {
    return a.ecc >= 0 and a.ecc <= max_ecc and a.omega_dot <= 0 and a.omega_dot / std.math.pi >= min_omega_dot_semicircles and
        field.fits(Packet, &reduced(8), &a) and field.fits(Packet, &midi(8), &a);
}

fn prn(a: *const Packet) i64 {
    return a.sat.prn();
}

fn health(a: *const Packet) i64 {
    if (a.carriers) |bits| return bits;
    return switch (@as(u5, @truncate(a.health))) {
        0b00010, 0b11100, 0b11111 => 0b111,
        0b10111 => 0b100,
        0b11010 => 0b010,
        else => 0,
    };
}

fn deltaA(a: *const Packet) f64 {
    return a.sqrt_a * a.sqrt_a - constants.a_ref;
}

fn phi0(a: *const Packet) f64 {
    return a.m0 + a.w;
}

fn deltaI(a: *const Packet) f64 {
    return a.i0 - constants.nominal_i0;
}

comptime {
    std.debug.assert(field.totalWidth(Reference, &reference) == 21);
    std.debug.assert(field.totalWidth(Packet, &reduced(6)) == 31);
    std.debug.assert(field.totalWidth(Packet, &reduced(8)) == 33);
    std.debug.assert(field.totalWidth(Packet, &midi(6)) == 128);
    std.debug.assert(field.totalWidth(Packet, &midi(8)) == 130);
}
