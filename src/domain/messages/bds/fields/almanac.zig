const std = @import("std");
const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const field = @import("base/binary/field");
const records = @import("domain/navigation/records");
const bds_records = @import("domain/navigation/records/bds");
const constants = @import("domain/navigation/orbit/constants/bds");
pub const Reference = almanac_epoch.Reference;
pub const Slot = struct {
    alm: *const records.KeplerAlmanac,
    sat_type: bds_records.SatType,

    pub fn init(a: *const records.KeplerAlmanac) Slot {
        return .{ .alm = a, .sat_type = bds_records.satTypeOf(a.sat.prn(), a.sqrt_a) };
    }

    pub fn representable(a: records.KeplerAlmanac) bool {
        if (!bds_records.almanacTimeFits(a.toa)) return false;
        const slot: Slot = .{ .alm = &a, .sat_type = bds_records.satTypeOf(a.sat.prn(), a.sqrt_a) };
        const packet: Packet = .{ .slot = slot, .reference = .{ .wna = 0, .toa = 0 } };
        if (!field.fits(Packet, &reduced, &packet) or !field.fits(Packet, &midi, &packet)) return false;
        return true;
    }
};
pub const Packet = struct { slot: ?Slot, reference: Reference };

pub const reference = almanac_epoch.rows;
const P = field.Field(Packet);
pub const reduced = [_]P{
    .{ .name = "prn", .width = 6, .src = .{ .computed_int = &almPrn } },
    .{ .name = "sat_type", .width = 2, .src = .{ .computed_int = &almSatType } },
    .{ .name = "delta_a", .width = 8, .repr = .twos, .scale_log2 = 9, .src = .{ .computed = &almDeltaA } },
    .{ .name = "omega0", .width = 7, .repr = .twos, .scale_log2 = -6, .semicircles = true, .periodic = true, .src = .{ .computed = &almField("omega0") } },
    .{ .name = "phi0", .width = 7, .repr = .twos, .scale_log2 = -6, .semicircles = true, .periodic = true, .src = .{ .computed = &almPhi0 } },
    .{ .name = "health", .width = 8, .src = .{ .computed_int = &almHealth } },
};

pub const midi = [_]P{
    .{ .name = "prna", .width = 6, .src = .{ .computed_int = &almPrn } },
    .{ .name = "sat_type_a", .width = 2, .src = .{ .computed_int = &almSatType } },
    .{ .name = "wna_m", .width = 13, .src = .{ .computed_int = &almWna } },
    .{ .name = "toa_m", .width = 8, .src = .{ .computed_int = &almToa } },
    .{ .name = "ecc_a", .width = 11, .scale_log2 = -16, .src = .{ .computed = &almField("ecc") } },
    .{ .name = "delta_i", .width = 11, .repr = .twos, .scale_log2 = -14, .semicircles = true, .src = .{ .computed = &almDeltaI } },
    .{ .name = "sqrt_a_a", .width = 17, .scale_log2 = -4, .src = .{ .computed = &almField("sqrt_a") } },
    .{ .name = "omega0_a", .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .computed = &almField("omega0") } },
    .{ .name = "omega_dot_a", .width = 11, .repr = .twos, .scale_log2 = -33, .semicircles = true, .src = .{ .computed = &almField("omega_dot") } },
    .{ .name = "w_a", .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .computed = &almField("w") } },
    .{ .name = "m0_a", .width = 16, .repr = .twos, .scale_log2 = -15, .semicircles = true, .periodic = true, .src = .{ .computed = &almField("m0") } },
    .{ .name = "af0_a", .width = 11, .repr = .twos, .scale_log2 = -20, .src = .{ .computed = &almField("af0") } },
    .{ .name = "af1_a", .width = 10, .repr = .twos, .scale_log2 = -37, .src = .{ .computed = &almField("af1") } },
    .{ .name = "health_a", .width = 8, .src = .{ .computed_int = &almHealth } },
};

fn almPrn(p: *const Packet) i64 {
    const a = p.slot orelse return 0;
    return a.alm.sat.prn();
}
fn almSatType(p: *const Packet) i64 {
    const a = p.slot orelse return 0;
    return @backingInt(a.sat_type);
}
fn almHealth(p: *const Packet) i64 {
    const a = p.slot orelse return 0;
    return a.alm.health & 0xFF;
}
fn almDeltaA(p: *const Packet) f64 {
    const a = p.slot orelse return 0;
    return a.alm.sqrt_a * a.alm.sqrt_a - constants.aRef(a.sat_type);
}
fn almPhi0(p: *const Packet) f64 {
    const a = p.slot orelse return 0;
    return a.alm.m0 + a.alm.w;
}
fn almField(comptime name: []const u8) fn (*const Packet) f64 {
    return struct {
        fn f(p: *const Packet) f64 {
            const a = p.slot orelse return 0;
            return @field(a.alm, name);
        }
    }.f;
}
fn almDeltaI(p: *const Packet) f64 {
    const a = p.slot orelse return 0;
    return a.alm.i0 - constants.almanacInclinationReference(a.sat_type == .geo);
}
fn almWna(p: *const Packet) i64 {
    return if (p.slot == null) 0 else p.reference.wna;
}
fn almToa(p: *const Packet) i64 {
    return if (p.slot == null) 0 else p.reference.toa;
}

comptime {
    std.debug.assert(field.totalWidth(Reference, &reference) == 21);
    std.debug.assert(field.totalWidth(Packet, &reduced) == 38);
    std.debug.assert(field.totalWidth(Packet, &midi) == 156);
}
