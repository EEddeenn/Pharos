const field = @import("base/binary/field");
const records = @import("domain/navigation/records");
const galileo_records = @import("domain/navigation/records/galileo");
const reference = @import("domain/navigation/reference");
pub const toe_step_ms = 60_000;
pub const Ctx = struct { wn: u12 = 0, tow: u20 = 0 };

/// The shared I/NAV and F/NAV fields, also used to admit a raw record before a leg is prepared.
pub fn Fields(comptime T: type) type {
    return struct {
        const E = field.Field(T);
        pub const iod_nav: E = .{ .name = "iod_nav", .width = 10, .src = .{ .field = "iod_nav" } };
        pub const svid: E = .{ .name = "svid", .width = 6, .src = .{ .computed_int = &prn } };
        pub const sisa: E = .{ .name = "sisa", .width = 8, .renamed = true, .src = .{ .field = "sisa_index" } };
        pub const toe: E = .{ .name = "toe", .width = 14, .src = .{ .computed_int = &toeMinutes } };
        pub const m0: E = .{ .name = "m0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.m0" } };
        pub const delta_n: E = .{ .name = "delta_n", .width = 16, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.delta_n" } };
        pub const ecc: E = .{ .name = "ecc", .width = 32, .scale_log2 = -33, .src = .{ .field = "eph.ecc" } };
        pub const sqrt_a: E = .{ .name = "sqrt_a", .width = 32, .scale_log2 = -19, .src = .{ .field = "eph.sqrt_a" } };
        pub const omega0: E = .{ .name = "omega0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.omega0" } };
        pub const @"i0": E = .{ .name = "i0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .src = .{ .field = "eph.i0" } };
        pub const w: E = .{ .name = "w", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.w" } };
        pub const omega_dot: E = .{ .name = "omega_dot", .width = 24, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.omega_dot" } };
        pub const idot: E = .{ .name = "idot", .width = 14, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.idot" } };
        pub const cuc: E = .{ .name = "cuc", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cuc" } };
        pub const cus: E = .{ .name = "cus", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cus" } };
        pub const crc: E = .{ .name = "crc", .width = 16, .repr = .twos, .scale_log2 = -5, .src = .{ .field = "eph.crc" } };
        pub const crs: E = .{ .name = "crs", .width = 16, .repr = .twos, .scale_log2 = -5, .src = .{ .field = "eph.crs" } };
        pub const cic: E = .{ .name = "cic", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cic" } };
        pub const cis: E = .{ .name = "cis", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cis" } };
        pub const toc: E = .{ .name = "toc", .width = 14, .src = .{ .computed_int = &tocMinutes } };
        pub const af0: E = .{ .name = "af0", .width = 31, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "eph.af0" } };
        pub const af1: E = .{ .name = "af1", .width = 21, .repr = .twos, .scale_log2 = -46, .src = .{ .field = "eph.af1" } };
        pub const af2: E = .{ .name = "af2", .width = 6, .repr = .twos, .scale_log2 = -59, .src = .{ .field = "eph.af2" } };
        pub const bgd_e1e5a: E = .{ .name = "bgd_e1e5a", .width = 10, .repr = .twos, .scale_log2 = -32, .src = .{ .field = "bgd_e1e5a" } };
        pub const bgd_e1e5b: E = .{ .name = "bgd_e1e5b", .width = 10, .repr = .twos, .scale_log2 = -32, .src = .{ .field = "bgd_e1e5b" } };

        pub const all = [_]E{ iod_nav, svid, sisa, toe, m0, delta_n, ecc, sqrt_a, omega0, @"i0", w, omega_dot, idot, cuc, cus, crc, crs, cic, cis, toc, af0, af1, af2, bgd_e1e5a, bgd_e1e5b };

        fn prn(e: *const T) i64 {
            return e.eph.sat.prn();
        }
        fn toeMinutes(e: *const T) i64 {
            return e.eph.toe.msOfWeek() / toe_step_ms;
        }
        fn tocMinutes(e: *const T) i64 {
            return e.eph.toc.msOfWeek() / toe_step_ms;
        }
    };
}

pub fn misfit(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    const input = .{
        .eph = e.parameters(),
        .iod_nav = reference.galileoIssue(e),
        .sisa_index = switch (e.extra) {
            .inav => |x| x.sisa_index,
            .fnav => |x| x.sisa_index,
            else => galileo_records.sisa_napa,
        },
        .bgd_e1e5a = e.group_delay.get(.bgd_e1e5a) orelse 0,
        .bgd_e1e5b = e.group_delay.get(.bgd_e1e5b) orelse 0,
    };
    const T = @TypeOf(input);
    return field.misfit(T, &Fields(T).all, &input);
}
