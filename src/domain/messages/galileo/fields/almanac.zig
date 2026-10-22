const std = @import("std");
const almanac_epoch = @import("domain/navigation/almanac_epoch");
const gnss_types = @import("domain/gnss_types");
const field = @import("base/binary/field");
const time = @import("domain/time/gps");
const records = @import("domain/navigation/records");
const constants = @import("domain/navigation/orbit/constants/galileo");
const Alm = records.KeplerAlmanac;
pub const t0a_step_ms = almanac_epoch.galileo_toa_step_ms;
pub const Group = struct { sv: [3]?*const Alm, iod_a: u4, wna: u2, t0a: u10 };
const G = field.Field(Group);
const empty_health: i64 = 0b0101;
const empty_health_e5a: i64 = 0b01;

const tail: []const [:0]const u8 = &.{ "af0", "af1" };
const slot_rows = svRows(0, head) ++ svRows(0, tail);

pub const head: []const [:0]const u8 = &.{ "svid", "delta_sqrt_a", "ecc", "w", "delta_i", "omega0", "omega_dot", "m0" };
pub const almanac_head = [_]G{
    .{ .name = "iod_a", .width = 4, .src = .{ .field = "iod_a" } },
    .{ .name = "wna", .width = 2, .src = .{ .field = "wna" } },
    .{ .name = "t0a", .width = 10, .src = .{ .field = "t0a" } },
};

pub const Almanacs = struct {
    entries: [36]?*const Alm,
    iod_a: u4,
    wna: u2,
    t0a: u10,

    pub fn init(records_in: []const Alm, selected: gnss_types.SatSet, epoch: time.GpsTime) Almanacs {
        const gst = epoch.inScale(.gal);
        var out: Almanacs = .{ .entries = @splat(null), .iod_a = 0, .wna = @intCast(@mod(gst.period, 4)), .t0a = @intCast(gst.ms / t0a_step_ms) };
        for (records_in) |*a| if (selected.contains(a.sat)) {
            out.entries[a.sat.index] = a;
        };
        for (out.entries) |entry| if (entry) |a| {
            out.iod_a = @truncate(a.iod);
            break;
        };
        return out;
    }

    pub fn group(self: *const Almanacs, index: u4) Group {
        const first: usize = 3 * @as(usize, index);
        return .{ .sv = self.entries[first..][0..3].*, .iod_a = self.iod_a, .wna = self.wna, .t0a = self.t0a };
    }
};

pub fn misfit(a: Alm) ?[:0]const u8 {
    const gst = a.toa.inScale(.gal);
    if (gst.sub_ms != 0 or gst.ms % t0a_step_ms != 0) return "t0a";

    const group: Group = .{ .sv = .{ &a, null, null }, .iod_a = 0, .wna = 0, .t0a = 0 };
    const row = field.misfit(Group, &slot_rows, &group) orelse return null;
    inline for (head ++ tail) |name| if (std.mem.eql(u8, row, name ++ "_1")) return name;
    return row;
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
