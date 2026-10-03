const std = @import("std");
const field = @import("../../codec.zig").field;
const time = @import("../../core.zig").time;
const records = @import("../records.zig");
const time_parameters = @import("time_parameters.zig");
const constants = @import("constants.zig");

const Alm = records.KeplerAlmanac;

pub const t0a_step_ms = 600_000;

pub const Group = struct { sv: [3]?Alm, iod_a: u4, wna: u2, t0a: u10, ggto: time_parameters.Ggto };
const G = field.Field(Group);

const empty_health: i64 = 0b0101;
const empty_health_e5a: i64 = 0b01;

fn representable(a: Alm) bool {
    return misfit(a) == null;
}

pub fn misfit(a: Alm) ?[:0]const u8 {
    const gst = a.toa.inScale(.gal);
    if (gst.sub_ms != 0 or gst.ms % t0a_step_ms != 0) return "t0a";

    const group: Group = .{ .sv = .{ a, null, null }, .iod_a = 0, .wna = 0, .t0a = 0, .ggto = .{} };
    const row = field.misfit(Group, &slot_rows, &group) orelse return null;
    inline for (head ++ tail) |name| if (std.mem.eql(u8, row, name ++ "_1")) return name;
    return row;
}

const tail: []const [:0]const u8 = &.{ "af0", "af1" };
const slot_rows = svRows(0, head) ++ svRows(0, tail);

fn almField(comptime k: usize, comptime name: []const u8) fn (*const Group) f64 {
    return struct {
        fn f(g: *const Group) f64 {
            const a = g.sv[k] orelse return 0;
            return @field(a, name);
        }
    }.f;
}
fn almDeltaSqrtA(comptime k: usize) fn (*const Group) f64 {
    return struct {
        fn f(g: *const Group) f64 {
            const a = g.sv[k] orelse return 0;
            return a.sqrt_a - constants.sqrt_a_ref;
        }
    }.f;
}
fn almDeltaI(comptime k: usize) fn (*const Group) f64 {
    return struct {
        fn f(g: *const Group) f64 {
            const a = g.sv[k] orelse return 0;
            return a.i0 - constants.nominal_i0;
        }
    }.f;
}
fn almSvid(comptime k: usize) fn (*const Group) i64 {
    return struct {
        fn f(g: *const Group) i64 {
            const a = g.sv[k] orelse return 0;
            return a.sat.prn();
        }
    }.f;
}
fn almHealth(comptime k: usize) fn (*const Group) i64 {
    return struct {
        fn f(g: *const Group) i64 {
            const a = g.sv[k] orelse return empty_health;
            return a.health & 0xF;
        }
    }.f;
}
fn almHealthE5a(comptime k: usize) fn (*const Group) i64 {
    return struct {
        fn f(g: *const Group) i64 {
            const a = g.sv[k] orelse return empty_health_e5a;
            return (a.health >> 4) & 0x3;
        }
    }.f;
}

pub fn svRows(comptime k: usize, comptime names: []const [:0]const u8) [names.len]G {
    var rows: [names.len]G = undefined;
    for (names, 0..) |name, i| rows[i] = svRow(k, name);
    return rows;
}

pub fn svRow(comptime k: usize, comptime name: [:0]const u8) G {
    const tag = std.fmt.comptimePrint("{s}_{d}", .{ name, k + 1 });
    if (std.mem.eql(u8, name, "svid")) return .{ .name = tag, .width = 6, .src = .{ .computed_int = &almSvid(k) } };
    if (std.mem.eql(u8, name, "delta_sqrt_a")) return .{ .name = tag, .width = 13, .repr = .twos, .scale_log2 = -9, .src = .{ .computed = &almDeltaSqrtA(k) } };
    if (std.mem.eql(u8, name, "ecc")) return .{ .name = tag, .width = 11, .scale_log2 = -16, .src = .{ .computed = &almField(k, "ecc") } };
    if (std.mem.eql(u8, name, "w")) return .{ .name = tag, .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .computed = &almField(k, "w") } };
    if (std.mem.eql(u8, name, "delta_i")) return .{ .name = tag, .width = 11, .repr = .twos, .scale_log2 = -14, .semicircles = true, .src = .{ .computed = &almDeltaI(k) } };
    if (std.mem.eql(u8, name, "omega0")) return .{ .name = tag, .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .computed = &almField(k, "omega0") } };
    if (std.mem.eql(u8, name, "omega_dot")) return .{ .name = tag, .width = 11, .repr = .twos, .scale_log2 = -33, .semicircles = true, .src = .{ .computed = &almField(k, "omega_dot") } };
    if (std.mem.eql(u8, name, "m0")) return .{ .name = tag, .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .computed = &almField(k, "m0") } };
    if (std.mem.eql(u8, name, "af0")) return .{ .name = tag, .width = 16, .repr = .twos, .scale_log2 = -19, .src = .{ .computed = &almField(k, "af0") } };
    if (std.mem.eql(u8, name, "af1")) return .{ .name = tag, .width = 13, .repr = .twos, .scale_log2 = -38, .src = .{ .computed = &almField(k, "af1") } };
    if (std.mem.eql(u8, name, "health")) return .{ .name = tag, .width = 4, .src = .{ .computed_int = &almHealth(k) } };
    if (std.mem.eql(u8, name, "e5a_health")) return .{ .name = tag, .width = 2, .src = .{ .computed_int = &almHealthE5a(k) } };
    @compileError("unknown almanac row " ++ name);
}

pub const head: []const [:0]const u8 = &.{ "svid", "delta_sqrt_a", "ecc", "w", "delta_i", "omega0", "omega_dot", "m0" };

pub const almanac_head = [_]G{
    .{ .name = "iod_a", .width = 4, .src = .{ .field = "iod_a" } },
    .{ .name = "wna", .width = 2, .src = .{ .field = "wna" } },
    .{ .name = "t0a", .width = 10, .src = .{ .field = "t0a" } },
};

pub fn almanacGroups(almanacs: []const Alm, ggto: time_parameters.Ggto, t: time.GpsTime) [12]Group {
    var by_sv: [36]?Alm = @splat(null);
    for (almanacs) |a| {
        if (!representable(a)) continue;
        by_sv[a.sat.prn() - 1] = a;
    }

    const reference: ?Alm = for (by_sv) |entry| {
        if (entry) |a| break a;
    } else null;

    if (reference) |r| {
        for (&by_sv) |*entry| {
            const a = entry.* orelse continue;
            if (!a.toa.eql(r.toa)) entry.* = null;
        }
    }

    const toa = if (reference) |a| a.toa else t;
    const gst = toa.inScale(.gal);
    const t0a: u10 = @intCast(if (reference != null) @divExact(gst.ms, t0a_step_ms) else gst.ms / t0a_step_ms);
    const iod_a: u4 = if (reference) |a| @truncate(a.iod) else 0;
    var groups: [12]Group = undefined;
    for (&groups, 0..) |*g, i| g.* = .{
        .sv = .{ by_sv[3 * i], by_sv[3 * i + 1], by_sv[3 * i + 2] },
        .iod_a = iod_a,
        .wna = @intCast(@mod(gst.period, 4)),
        .t0a = t0a,
        .ggto = ggto,
    };
    return groups;
}
