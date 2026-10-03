const field = @import("../../codec.zig").field;
const records = @import("../records.zig");
const galileo_records = @import("records.zig");

pub const toe_step_ms = 60_000;

pub const Ctx = struct { wn: u12 = 0, tow: u20 = 0 };

pub const Eph = records.KeplerEphemeris;
const E = field.Field(Eph);

fn issue(e: *const Eph) i64 {
    return switch (e.extra) {
        .inav => |x| x.iod_nav,
        .fnav => |x| x.iod_nav,
        else => e.iode & 0x3ff,
    };
}

fn sisaOf(e: *const Eph) i64 {
    return switch (e.extra) {
        .inav => |x| x.sisa_index,
        .fnav => |x| x.sisa_index,
        else => galileo_records.sisa_napa,
    };
}

fn prn(e: *const Eph) i64 {
    return e.sat.prn();
}
fn toeMinutes(e: *const Eph) i64 {
    return e.toe.msOfWeek() / toe_step_ms;
}
fn tocMinutes(e: *const Eph) i64 {
    return e.toc.msOfWeek() / toe_step_ms;
}
fn delay(comptime term: records.GroupDelayTerm) fn (*const Eph) ?f64 {
    return struct {
        fn f(e: *const Eph) ?f64 {
            return e.group_delay.get(term);
        }
    }.f;
}

fn delayRange(comptime term: records.GroupDelayTerm) fn (*const Eph) f64 {
    return struct {
        fn f(e: *const Eph) f64 {
            return e.group_delay.get(term) orelse 0;
        }
    }.f;
}

fn ranged(comptime row: E, comptime term: records.GroupDelayTerm) E {
    var out = row;
    out.src = .{ .computed = &delayRange(term) };
    return out;
}

pub const iod_nav: E = .{ .name = "iod_nav", .width = 10, .src = .{ .computed_int = &issue } };
pub const svid: E = .{ .name = "svid", .width = 6, .src = .{ .computed_int = &prn } };
pub const sisa: E = .{ .name = "sisa", .width = 8, .src = .{ .computed_int = &sisaOf } };
pub const toe: E = .{ .name = "toe", .width = 14, .src = .{ .computed_int = &toeMinutes } };
pub const m0: E = .{ .name = "m0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "m0" } };
pub const delta_n: E = .{ .name = "delta_n", .width = 16, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "delta_n" } };
pub const ecc: E = .{ .name = "ecc", .width = 32, .scale_log2 = -33, .src = .{ .field = "ecc" } };
pub const sqrt_a: E = .{ .name = "sqrt_a", .width = 32, .scale_log2 = -19, .src = .{ .field = "sqrt_a" } };
pub const omega0: E = .{ .name = "omega0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "omega0" } };
pub const @"i0": E = .{ .name = "i0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .src = .{ .field = "i0" } };
pub const w: E = .{ .name = "w", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "w" } };
pub const omega_dot: E = .{ .name = "omega_dot", .width = 24, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "omega_dot" } };
pub const idot: E = .{ .name = "idot", .width = 14, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "idot" } };
pub const cuc: E = .{ .name = "cuc", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "cuc" } };
pub const cus: E = .{ .name = "cus", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "cus" } };
pub const crc: E = .{ .name = "crc", .width = 16, .repr = .twos, .scale_log2 = -5, .src = .{ .field = "crc" } };
pub const crs: E = .{ .name = "crs", .width = 16, .repr = .twos, .scale_log2 = -5, .src = .{ .field = "crs" } };
pub const cic: E = .{ .name = "cic", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "cic" } };
pub const cis: E = .{ .name = "cis", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "cis" } };
pub const toc: E = .{ .name = "toc", .width = 14, .src = .{ .computed_int = &tocMinutes } };
pub const af0: E = .{ .name = "af0", .width = 31, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "af0" } };
pub const af1: E = .{ .name = "af1", .width = 21, .repr = .twos, .scale_log2 = -46, .src = .{ .field = "af1" } };
pub const af2: E = .{ .name = "af2", .width = 6, .repr = .twos, .scale_log2 = -59, .src = .{ .field = "af2" } };
pub const bgd_e1e5a: E = .{ .name = "bgd_e1e5a", .width = 10, .repr = .twos, .scale_log2 = -32, .src = .{ .computed_opt = &delay(.bgd_e1e5a) } };
pub const bgd_e1e5b: E = .{ .name = "bgd_e1e5b", .width = 10, .repr = .twos, .scale_log2 = -32, .src = .{ .computed_opt = &delay(.bgd_e1e5b) } };

const rows = [_]E{ iod_nav, svid, sisa, toe, m0, delta_n, ecc, sqrt_a, omega0, @"i0", w, omega_dot, idot, cuc, cus, crc, crs, cic, cis, toc, af0, af1, af2, ranged(bgd_e1e5a, .bgd_e1e5a), ranged(bgd_e1e5b, .bgd_e1e5b) };

pub fn misfit(e: *const Eph) ?[:0]const u8 {
    return field.misfit(Eph, &rows, e);
}
