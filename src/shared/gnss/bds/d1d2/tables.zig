const std = @import("std");
const field = @import("../../../codec.zig").field;
const time = @import("../../../core.zig").time;
const records = @import("../../records.zig");
const reference = @import("../../reference.zig");
const sources = @import("sources.zig");
const word = @import("word.zig");
const klobuchar_fields = @import("../../klobuchar_fields.zig");

const Sv = sources.Sv;
const sowRow = sources.sowRow;
const rev = sources.rev;
const reserved = sources.reserved;

pub const Ctx = struct { sow_lsb: u12 = 0 };

const S = field.Field(Sv);

fn tgd1(s: *const Sv) f64 {
    return s.metadata.tgd1 * sources.tenths_of_ns_per_s;
}
fn tgd2(s: *const Sv) f64 {
    return s.metadata.tgd2 * sources.tenths_of_ns_per_s;
}
const toe: S = .{ .name = "toe_8s", .width = 17, .src = .{ .field = "metadata.toe_8s" } };

const klobuchar_rows = klobuchar_fields.rows(Sv, "klobuchar.");

const satellite_rows = [_]S{
    .{ .name = "sat_h1", .width = 1, .src = .{ .field = "metadata.sat_h1" } },
    .{ .name = "aodc", .width = 5, .src = .{ .field = "metadata.aodc" } },
    .{ .name = "urai", .width = 4, .src = .{ .field = "metadata.urai" } },
    .{ .name = "wn", .width = 13, .src = .{ .field = "metadata.wn" } },
    .{ .name = "toc_8s", .width = 17, .src = .{ .field = "metadata.toc_8s" } },
    .{ .name = "tgd1", .width = 10, .repr = .twos, .src = .{ .computed = &tgd1 } },
    .{ .name = "tgd2", .width = 10, .repr = .twos, .src = .{ .computed = &tgd2 } },
};

pub const sf1 = [_]S{sowRow(Sv)} ++ satellite_rows ++ klobuchar_rows ++ [_]S{
    .{ .name = "af2", .width = 11, .repr = .twos, .scale_log2 = -66, .src = .{ .field = "eph.af2" } },
    .{ .name = "af0", .width = 24, .repr = .twos, .scale_log2 = -33, .src = .{ .field = "eph.af0" } },
    .{ .name = "af1", .width = 22, .repr = .twos, .scale_log2 = -50, .src = .{ .field = "eph.af1" } },
    .{ .name = "aode", .width = 5, .src = .{ .field = "metadata.aode" } },
};

pub const sf2 = [_]S{
    sowRow(Sv),
    .{ .name = "delta_n", .width = 16, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.delta_n" } },
    .{ .name = "cuc", .width = 18, .repr = .twos, .scale_log2 = -31, .src = .{ .field = "eph.cuc" } },
    .{ .name = "m0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.m0" } },
    .{ .name = "ecc", .width = 32, .scale_log2 = -33, .src = .{ .field = "eph.ecc" } },
    .{ .name = "cus", .width = 18, .repr = .twos, .scale_log2 = -31, .src = .{ .field = "eph.cus" } },
    .{ .name = "crc", .width = 18, .repr = .twos, .scale_log2 = -6, .src = .{ .field = "eph.crc" } },
    .{ .name = "crs", .width = 18, .repr = .twos, .scale_log2 = -6, .src = .{ .field = "eph.crs" } },
    .{ .name = "sqrt_a", .width = 32, .scale_log2 = -19, .src = .{ .field = "eph.sqrt_a" } },
    .{ .name = "toe_msb", .width = 2, .src = .{ .part = .{ .of = &toe, .shift = 15 } } },
};

pub const sf3 = [_]S{
    sowRow(Sv),
    .{ .name = "toe_mid", .width = 10, .src = .{ .part = .{ .of = &toe, .shift = 5 } } },
    .{ .name = "toe_lsb", .width = 5, .src = .{ .part = .{ .of = &toe, .shift = 0 } } },
    .{ .name = "i0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .src = .{ .field = "eph.i0" } },
    .{ .name = "cic", .width = 18, .repr = .twos, .scale_log2 = -31, .src = .{ .field = "eph.cic" } },
    .{ .name = "omega_dot", .width = 24, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.omega_dot" } },
    .{ .name = "cis", .width = 18, .repr = .twos, .scale_log2 = -31, .src = .{ .field = "eph.cis" } },
    .{ .name = "idot", .width = 14, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.idot" } },
    .{ .name = "omega0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.omega0" } },
    .{ .name = "w", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.w" } },
    rev(Sv),
};

fn d1(comptime name: []const u8) S {
    return field.rowOf(Sv, &(sf1 ++ sf2 ++ sf3), name);
}

fn part(comptime name: []const u8, comptime shift: u7) S.Part {
    return .{ .of = &d1(name), .shift = shift };
}

fn pnum1(comptime k: u4) S {
    return .{ .name = "pnum1", .width = 4, .src = .{ .constant = k } };
}
pub const d2_page1 = [_]S{ sowRow(Sv), pnum1(1) } ++ satellite_rows ++ field.reservedRows(Sv, "reserved_p1", 122);
pub const d2_page2 = [_]S{ sowRow(Sv), pnum1(2) } ++ klobuchar_rows ++ field.reservedRows(Sv, "reserved_p2", 118);
pub const d2_page3 = [_]S{
    sowRow(Sv),
    pnum1(3),
    reserved(Sv, "reserved_p3a", 38),
    d1("af0"),
    .{ .name = "af1_hi", .width = 4, .src = .{ .part = part("af1", 18) } },
} ++ field.reservedRows(Sv, "reserved_p3b", 116);
pub const d2_page4 = [_]S{
    sowRow(Sv),
    pnum1(4),
    .{ .name = "af1_lo", .width = 18, .src = .{ .part = part("af1", 0) } },
    d1("af2"),
    d1("aode"),
    d1("delta_n"),
    .{ .name = "cuc_hi", .width = 14, .src = .{ .part = part("cuc", 4) } },
} ++ field.reservedRows(Sv, "reserved_p4", 118);
pub const d2_page5 = [_]S{
    sowRow(Sv),
    pnum1(5),
    .{ .name = "cuc_lo", .width = 4, .src = .{ .part = part("cuc", 0) } },
    d1("m0"),
    d1("cus"),
    .{ .name = "ecc_hi", .width = 10, .src = .{ .part = part("ecc", 22) } },
} ++ field.reservedRows(Sv, "reserved_p5", 118);
pub const d2_page6 = [_]S{
    sowRow(Sv),
    pnum1(6),
    .{ .name = "ecc_lo", .width = 22, .src = .{ .part = part("ecc", 0) } },
    d1("sqrt_a"),
    .{ .name = "cic_hi", .width = 10, .src = .{ .part = part("cic", 8) } },
} ++ field.reservedRows(Sv, "reserved_p6", 118);
pub const d2_page7 = [_]S{
    sowRow(Sv),
    pnum1(7),
    .{ .name = "cic_lo", .width = 8, .src = .{ .part = part("cic", 0) } },
    d1("cis"),
    toe,
    .{ .name = "i0_hi", .width = 21, .src = .{ .part = part("i0", 11) } },
} ++ field.reservedRows(Sv, "reserved_p7", 118);
pub const d2_page8 = [_]S{
    sowRow(Sv),
    pnum1(8),
    .{ .name = "i0_lo", .width = 11, .src = .{ .part = part("i0", 0) } },
    d1("crc"),
    d1("crs"),
    .{ .name = "omega_dot_hi", .width = 19, .src = .{ .part = part("omega_dot", 5) } },
} ++ field.reservedRows(Sv, "reserved_p8", 116);
pub const d2_page9 = [_]S{
    sowRow(Sv),
    pnum1(9),
    .{ .name = "omega_dot_lo", .width = 5, .src = .{ .part = part("omega_dot", 0) } },
    d1("omega0"),
    .{ .name = "w_hi", .width = 27, .src = .{ .part = part("w", 5) } },
} ++ field.reservedRows(Sv, "reserved_p9", 118);
pub const d2_page10 = [_]S{
    sowRow(Sv),
    pnum1(10),
    .{ .name = "w_lo", .width = 5, .src = .{ .part = part("w", 0) } },
    d1("idot"),
} ++ field.reservedRows(Sv, "reserved_p10", 163);

pub fn decoded(sv: *const Sv) ?@import("../../kepler_parameters.zig").Parameters {
    const a = readBack(&sf1, sv) orelse return null;
    const b = readBack(&sf2, sv) orelse return null;
    const c = readBack(&sf3, sv) orelse return null;
    var out = sv.eph;
    inline for (.{ "af2", "af0", "af1" }) |name| @field(out, name) = field.value(Sv, &sf1, name, a);
    inline for (.{ "delta_n", "cuc", "m0", "ecc", "cus", "crc", "crs", "sqrt_a" }) |name| @field(out, name) = field.value(Sv, &sf2, name, b);
    inline for (.{ "i0", "cic", "omega_dot", "cis", "idot", "omega0", "w" }) |name| @field(out, name) = field.value(Sv, &sf3, name, c);
    out.a_dot = 0;
    out.delta_n_dot = 0;
    out.toe = floorTo8s(sv.eph.toe);
    out.toc = floorTo8s(sv.eph.toc);
    return out;
}

fn readBack(comptime layout: []const S, sv: *const Sv) ?field.Decoded(Sv, layout) {
    var bits: word.Info = .{};
    var w = bits.writer();
    field.encode(Sv, layout, sv, Ctx{}, &w) catch return null;
    return field.decode(Sv, layout, &bits.words);
}

pub fn floorTo8s(t: time.GpsTime) time.GpsTime {
    const bdt = t.inScale(.bds);
    return time.GpsTime.fromScaleWeekMs(.bds, bdt.period, bdt.ms / sources.toe_step_ms * sources.toe_step_ms, 0);
}

pub const FieldFailure = union(enum) {
    sf1: std.meta.FieldEnum(field.Decoded(Sv, &sf1)),
    sf2: std.meta.FieldEnum(field.Decoded(Sv, &sf2)),
    sf3: std.meta.FieldEnum(field.Decoded(Sv, &sf3)),

    pub fn name(self: FieldFailure) [:0]const u8 {
        return switch (self) {
            inline else => |row| @tagName(row),
        };
    }
};

pub fn failure(sv: *const Sv) ?FieldFailure {
    inline for (.{ "sf1", "sf2", "sf3" }) |subframe| {
        const rows = @field(@This(), subframe);
        inline for (rows, 0..) |row, i| {
            if (field.misfit(Sv, &.{row}, sv) != null) return @unionInit(FieldFailure, subframe, @enumFromInt(i));
        }
    }
    return null;
}

pub fn misfit(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    const parameters = e.parameters();
    const sv: Sv = .{ .eph = parameters, .metadata = sources.metadata(reference.Kepler.raw(e), &parameters), .klobuchar = .of(.zero) };
    return if (failure(&sv)) |failed| failed.name() else null;
}

comptime {
    for (.{ sf1, sf2, sf3, d2_page1, d2_page2, d2_page3, d2_page4, d2_page5, d2_page6, d2_page7, d2_page8, d2_page9, d2_page10 }) |layout| std.debug.assert(field.totalWidth(Sv, &layout) == word.info_bits);
}
