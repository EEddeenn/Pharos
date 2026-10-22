const std = @import("std");
const field = @import("base/binary/field");
const records = @import("domain/navigation/records");
const auxiliary = @import("domain/navigation/system_data");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const Parameters = @import("domain/messages/gps/lnav/content").Parameters;
const Alm = records.KeplerAlmanac;
const NoSource = field.NoSource;
pub const Ctx = struct { wn: u10, tow_next: u17, subframe: u3, isf: u1 = 0, alert: u1 = 0, page_sv_id: u6 = 0 };
const content_bits = 192;
const preamble = 0x8B;
const aodo_unavailable = 31;
const almanac_reference_inclination: f64 = 0.3;
const erd_unavailable = 0b100000;
const ai_unavailable = 0b10;
const page13_sv_id = 52;
const page17_sv_id = 55;
const page18_sv_id = 56;
const sf5_page25_sv_id = 51;
const sf4_page25_sv_id = 63;
const H = field.Field(NoSource);
pub const tlm = [_]H{
    .{ .name = "preamble", .width = 8, .src = .{ .constant = preamble } },
    .{ .name = "tlm_message", .width = 14, .src = .{ .constant = 0 } },
    .{ .name = "integrity_status", .width = 1, .src = .{ .ctx = "isf" } },
    .{ .name = "reserved_tlm", .width = 1, .src = .reserved },
};
pub const how = [_]H{
    .{ .name = "tow_next", .width = 17, .src = .{ .ctx = "tow_next" } },
    .{ .name = "alert", .width = 1, .src = .{ .ctx = "alert" } },
    .{ .name = "anti_spoof", .width = 1, .src = .{ .constant = 1 } },
    .{ .name = "subframe_id", .width = 3, .src = .{ .ctx = "subframe" } },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

const E = field.Field(Parameters);

pub const sf1 = [_]E{
    .{ .name = "wn", .width = 10, .src = .{ .ctx = "wn" } },
    .{ .name = "l2_codes", .width = 2, .src = .{ .field = "l2_codes" } },
    .{ .name = "ura_index", .width = 4, .src = .{ .field = "ura_index" } },
    .{ .name = "health", .width = 6, .src = .{ .field = "health" } },
    .{ .name = "iodc_msb", .width = 2, .src = .{ .computed_int = &iodcMsb } },
    .{ .name = "l2p_data", .width = 1, .src = .{ .field = "l2p_data" } },
    .{ .name = "reserved_w4", .width = 23, .src = .reserved },
    .{ .name = "reserved_w5", .width = 24, .src = .reserved },
    .{ .name = "reserved_w6", .width = 24, .src = .reserved },
    .{ .name = "reserved_w7", .width = 16, .src = .reserved },
    .{ .name = "tgd", .width = 8, .repr = .twos, .scale_log2 = -31, .src = .{ .field = "tgd" } },
    .{ .name = "iodc_lsb", .width = 8, .src = .{ .computed_int = &iodcLsb } },
    .{ .name = "toc", .width = 16, .scale_log2 = 4, .src = .{ .computed = &tocSow } },
    .{ .name = "af2", .width = 8, .repr = .twos, .scale_log2 = -55, .src = .{ .field = "eph.af2" } },
    .{ .name = "af1", .width = 16, .repr = .twos, .scale_log2 = -43, .src = .{ .field = "eph.af1" } },
    .{ .name = "af0", .width = 22, .repr = .twos, .scale_log2 = -31, .src = .{ .field = "eph.af0" } },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

pub const sf2 = [_]E{
    .{ .name = "iode", .width = 8, .src = .{ .field = "iode" } },
    .{ .name = "crs", .width = 16, .repr = .twos, .scale_log2 = -5, .src = .{ .field = "eph.crs" } },
    .{ .name = "delta_n", .width = 16, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.delta_n" } },
    .{ .name = "m0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.m0" } },
    .{ .name = "cuc", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cuc" } },
    .{ .name = "ecc", .width = 32, .scale_log2 = -33, .src = .{ .field = "eph.ecc" } },
    .{ .name = "cus", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cus" } },
    .{ .name = "sqrt_a", .width = 32, .scale_log2 = -19, .src = .{ .field = "eph.sqrt_a" } },
    .{ .name = "toe", .width = 16, .scale_log2 = 4, .src = .{ .computed = &toeSow } },
    .{ .name = "fit_interval", .width = 1, .src = .{ .field = "fit_interval" } },
    .{ .name = "aodo", .width = 5, .src = .{ .constant = aodo_unavailable } },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

pub const sf3 = [_]E{
    .{ .name = "cic", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cic" } },
    .{ .name = "omega0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.omega0" } },
    .{ .name = "cis", .width = 16, .repr = .twos, .scale_log2 = -29, .src = .{ .field = "eph.cis" } },
    .{ .name = "i0", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .src = .{ .field = "eph.i0" } },
    .{ .name = "crc", .width = 16, .repr = .twos, .scale_log2 = -5, .src = .{ .field = "eph.crc" } },
    .{ .name = "w", .width = 32, .repr = .twos, .scale_log2 = -31, .semicircles = true, .periodic = true, .src = .{ .field = "eph.w" } },
    .{ .name = "omega_dot", .width = 24, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.omega_dot" } },
    .{ .name = "iode", .width = 8, .src = .{ .field = "iode" } },
    .{ .name = "idot", .width = 14, .repr = .twos, .scale_log2 = -43, .semicircles = true, .src = .{ .field = "eph.idot" } },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

const A = field.Field(Alm);
const af0: A = .{ .name = "af0", .width = 11, .repr = .twos, .scale_log2 = -20, .src = .{ .field = "af0" } };
pub const almanac_page = [_]A{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .computed_int = &almPrn } },
    .{ .name = "ecc", .width = 16, .scale_log2 = -21, .src = .{ .field = "ecc" } },
    .{ .name = "toa", .width = 8, .scale_log2 = 12, .src = .{ .computed = &toaSow } },
    .{ .name = "delta_i", .width = 16, .repr = .twos, .scale_log2 = -19, .src = .{ .computed = &deltaI } },
    .{ .name = "omega_dot", .width = 16, .repr = .twos, .scale_log2 = -38, .semicircles = true, .src = .{ .field = "omega_dot" } },
    .{ .name = "health", .width = 8, .src = .{ .computed_int = &health8 } },
    .{ .name = "sqrt_a", .width = 24, .scale_log2 = -11, .src = .{ .field = "sqrt_a" } },
    .{ .name = "omega0", .width = 24, .repr = .twos, .scale_log2 = -23, .semicircles = true, .periodic = true, .src = .{ .field = "omega0" } },
    .{ .name = "w", .width = 24, .repr = .twos, .scale_log2 = -23, .semicircles = true, .periodic = true, .src = .{ .field = "w" } },
    .{ .name = "m0", .width = 24, .repr = .twos, .scale_log2 = -23, .semicircles = true, .periodic = true, .src = .{ .field = "m0" } },
    .{ .name = "af0_msb", .width = 8, .src = .{ .part = .{ .of = &af0, .shift = 3 } } },
    .{ .name = "af1", .width = 11, .repr = .twos, .scale_log2 = -38, .src = .{ .field = "af1" } },
    .{ .name = "af0_lsb", .width = 3, .src = .{ .part = .{ .of = &af0, .shift = 0 } } },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

const alt64: u64 = 0x5555_5555_5555_5555;
const alt54: u64 = 0x15_5555_5555_5555;
pub const filler_page = [_]H{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .ctx = "page_sv_id" } },
    .{ .name = "filler_a", .width = 64, .src = .{ .constant = alt64 } },
    .{ .name = "filler_b", .width = 64, .src = .{ .constant = alt64 } },
    .{ .name = "filler_c", .width = 54, .src = .{ .constant = alt54 } },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};
pub const page13 = [_]H{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .constant = page13_sv_id } },
    .{ .name = "ai", .width = 2, .src = .{ .constant = ai_unavailable } },
} ++ erdRows() ++ [_]H{.{ .name = "fill", .width = 2, .src = .parity_fill }};

pub const Page17 = struct { characters: [22]u8 };
const T = field.Field(Page17);
pub const page17 = [_]T{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .constant = page17_sv_id } },
} ++ characterRows() ++ [_]T{
    .{ .name = "reserved_system", .width = 6, .src = .reserved },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

pub const Page18 = struct {
    klobuchar: klobuchar_fields.Coefficients,
    a1: f64,
    a0: f64,
    tot_s: u32,
    wn_t: u8,
    delta_tls: i8,
    wn_lsf: u8,
    dn: u8,
    delta_tlsf: i8,

    pub fn init(klobuchar: klobuchar_fields.Coefficients, utc: auxiliary.UtcParams, leap: auxiliary.LeapSecondSchedule) Page18 {
        return .{
            .klobuchar = klobuchar,
            .a1 = utc.a1,
            .a0 = utc.a0,
            .tot_s = utc.tot_s,
            .wn_t = @truncate(utc.wn_t),
            .delta_tls = leap.delta_tls,
            .wn_lsf = @truncate(leap.wn_lsf),
            .dn = leap.dn,
            .delta_tlsf = leap.delta_tlsf,
        };
    }
};
const P = field.Field(Page18);

pub const page18 = [_]P{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .constant = page18_sv_id } },
} ++ klobuchar_fields.rows(Page18, "klobuchar.") ++ [_]P{
    .{ .name = "a1", .width = 24, .repr = .twos, .scale_log2 = -50, .src = .{ .field = "a1" } },
    .{ .name = "a0", .width = 32, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "a0" } },
    .{ .name = "tot", .width = 8, .scale_log2 = 12, .src = .{ .computed = &totScaled } },
    .{ .name = "wn_t", .width = 8, .src = .{ .field = "wn_t" } },
    .{ .name = "delta_tls", .width = 8, .repr = .twos, .src = .{ .field = "delta_tls" } },
    .{ .name = "wn_lsf", .width = 8, .src = .{ .field = "wn_lsf" } },
    .{ .name = "dn", .width = 8, .src = .{ .field = "dn" } },
    .{ .name = "delta_tlsf", .width = 8, .repr = .twos, .src = .{ .field = "delta_tlsf" } },
    .{ .name = "reserved_w10", .width = 14, .src = .reserved },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

pub const Health = struct {
    toa: u8,
    wna: u8,
    sv: [32]u6,
    as_config: [32]u4,
};
const S = field.Field(Health);

pub const sf5_page25 = [_]S{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .constant = sf5_page25_sv_id } },
    .{ .name = "toa", .width = 8, .src = .{ .field = "toa" } },
    .{ .name = "wna", .width = 8, .src = .{ .field = "wna" } },
} ++ healthRows(1, 24) ++ [_]S{
    .{ .name = "reserved_w10a", .width = 6, .src = .reserved },
    .{ .name = "reserved_w10b", .width = 16, .src = .reserved },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

pub const sf4_page25 = [_]S{
    .{ .name = "data_id", .width = 2, .src = .{ .constant = 1 } },
    .{ .name = "sv_id", .width = 6, .src = .{ .constant = sf4_page25_sv_id } },
} ++ asRows() ++ [_]S{
    .{ .name = "reserved_w8", .width = 2, .src = .reserved },
} ++ healthRows(25, 32) ++ [_]S{
    .{ .name = "reserved_w10", .width = 4, .src = .reserved },
    .{ .name = "fill", .width = 2, .src = .parity_fill },
};

pub const sf4_page_ids = [25]u6{ 57, 25, 26, 27, 28, 57, 29, 30, 31, 32, 57, 62, 52, 53, 54, 57, 55, 56, 58, 59, 57, 60, 61, 62, 63 };

pub fn misfit(e: *const Parameters) ?[:0]const u8 {
    inline for (.{ &sf1, &sf2, &sf3 }) |rows| if (field.misfit(Parameters, rows, e)) |name| return name;
    if (e.iode != e.iodc & 0xFF) return "iode";
    return null;
}

fn iodcMsb(e: *const Parameters) i64 {
    return e.iodc >> 8;
}
fn iodcLsb(e: *const Parameters) i64 {
    return e.iodc & 0xFF;
}
fn tocSow(e: *const Parameters) f64 {
    return @as(f64, @floatFromInt(e.eph.toc.msOfWeek())) / 1000.0;
}
fn toeSow(e: *const Parameters) f64 {
    return @as(f64, @floatFromInt(e.eph.toe.msOfWeek())) / 1000.0;
}

fn almPrn(a: *const Alm) i64 {
    return a.sat.prn();
}
fn toaSow(a: *const Alm) f64 {
    return @as(f64, @floatFromInt(a.toa.msOfWeek())) / 1000.0;
}
fn deltaI(a: *const Alm) f64 {
    return a.i0 / std.math.pi - almanac_reference_inclination;
}
fn health8(a: *const Alm) i64 {
    return a.health & 0xFF;
}

fn erdRows() [30]H {
    var rows: [30]H = undefined;
    for (&rows, 1..) |*r, k| r.* = .{ .name = std.fmt.comptimePrint("erd_{d:0>2}", .{k}), .width = 6, .src = .{ .constant = erd_unavailable } };
    return rows;
}

fn characterRows() [22]T {
    var rows: [22]T = undefined;
    for (&rows, 0..) |*r, k| {
        const f = struct {
            fn get(p: *const Page17) i64 {
                return p.characters[k];
            }
        };
        r.* = .{ .name = std.fmt.comptimePrint("character_{d:0>2}", .{k + 1}), .width = 8, .src = .{ .computed_int = &f.get } };
    }
    return rows;
}

fn totScaled(p: *const Page18) f64 {
    return @floatFromInt(p.tot_s);
}

fn healthRow(comptime k: u8) S {
    const f = struct {
        fn get(h: *const Health) i64 {
            return h.sv[k - 1];
        }
    };
    return .{ .name = std.fmt.comptimePrint("health_{d:0>2}", .{k}), .width = 6, .src = .{ .computed_int = &f.get } };
}

fn asRow(comptime k: u8) S {
    const f = struct {
        fn get(h: *const Health) i64 {
            return h.as_config[k - 1];
        }
    };
    return .{ .name = std.fmt.comptimePrint("as_{d:0>2}", .{k}), .width = 4, .src = .{ .computed_int = &f.get } };
}

fn healthRows(comptime first: u8, comptime last: u8) [last - first + 1]S {
    var rows: [last - first + 1]S = undefined;
    for (&rows, 0..) |*r, i| r.* = healthRow(first + i);
    return rows;
}

fn asRows() [32]S {
    var rows: [32]S = undefined;
    for (&rows, 0..) |*r, i| r.* = asRow(i + 1);
    return rows;
}

comptime {
    const w = field.totalWidth;
    std.debug.assert(w(NoSource, &tlm) == 24 and w(NoSource, &how) == 24);
    for (.{ sf1, sf2, sf3 }) |layout| std.debug.assert(w(Parameters, &layout) == content_bits);
    std.debug.assert(w(Alm, &almanac_page) == content_bits and w(NoSource, &filler_page) == content_bits);
    std.debug.assert(w(Page18, &page18) == content_bits and w(Health, &sf5_page25) == content_bits and w(Health, &sf4_page25) == content_bits);
    std.debug.assert(w(NoSource, &page13) == content_bits and w(Page17, &page17) == content_bits);
}
