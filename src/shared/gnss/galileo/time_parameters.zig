const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const auxiliary = @import("../auxiliary.zig");

pub const Utc = struct {
    a0: f64,
    a1: f64,
    delta_tls: i8,
    t0t_h: u8,
    wnot: u8,
    wn_lsf: u8,
    dn: u8,
    delta_tlsf: i8,
};

pub const Ggto = struct { a0g: f64 = -0x1p-35, a1g: f64 = -0x1p-51, t0g_h: u8 = 255, wn0g: u6 = 63 };

pub const utc_rows = [_]field.Field(Utc){
    .{ .name = "a0", .width = 32, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "a0" } },
    .{ .name = "a1", .width = 24, .repr = .twos, .scale_log2 = -50, .src = .{ .field = "a1" } },
    .{ .name = "delta_tls", .width = 8, .repr = .twos, .src = .{ .field = "delta_tls" } },
    .{ .name = "t0t_h", .width = 8, .src = .{ .field = "t0t_h" } },
    .{ .name = "wnot", .width = 8, .src = .{ .field = "wnot" } },
    .{ .name = "wn_lsf", .width = 8, .src = .{ .field = "wn_lsf" } },
    .{ .name = "dn", .width = 3, .src = .{ .field = "dn" } },
    .{ .name = "delta_tlsf", .width = 8, .repr = .twos, .src = .{ .field = "delta_tlsf" } },
};

const G = field.Field(Ggto);
pub const a0g: G = .{ .name = "a0g", .width = 16, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "a0g" } };
pub const a1g: G = .{ .name = "a1g", .width = 12, .repr = .twos, .scale_log2 = -51, .src = .{ .field = "a1g" } };
pub const t0g_h: G = .{ .name = "t0g_h", .width = 8, .src = .{ .field = "t0g_h" } };
pub const wn0g: G = .{ .name = "wn0g", .width = 6, .src = .{ .field = "wn0g" } };
const ggto_rows = [_]G{ a0g, a1g, t0g_h, wn0g };

const wn8_half_range = 127;
const wn6_half_range = 31;
const wn6_modulus = 64;

pub fn utcBlock(in: ?auxiliary.UtcParams, t: time.GpsTime) ?Utc {
    const p = in orelse return null;
    const leap = p.leap orelse return null;
    if (p.a2 != 0 or p.tot_s % time.s_per_hour != 0 or @abs(t.week() - p.wn_t) > wn8_half_range) return null;
    if (leap.delta_tls != leap.delta_tlsf and @abs(t.week() - leap.wn_lsf) > wn8_half_range) return null;

    const out: Utc = .{
        .a0 = p.a0,
        .a1 = p.a1,
        .delta_tls = leap.delta_tls,
        .t0t_h = @intCast(p.tot_s / time.s_per_hour),
        .wnot = @truncate(p.wn_t),
        .wn_lsf = @truncate(leap.wn_lsf),
        .dn = leap.dn,
        .delta_tlsf = leap.delta_tlsf,
    };
    return if (field.fits(Utc, &utc_rows, &out)) out else null;
}

pub fn ggtoBlock(in: ?auxiliary.TimeOffset, t: time.GpsTime) Ggto {
    const g = in orelse return .{};
    const reference = g.reference orelse return .{};
    const gst = reference.inScale(.gal);
    if (g.a2 != 0 or gst.sub_ms != 0 or gst.ms % time.ms_per_hour != 0 or
        @abs(gst.period - t.inScale(.gal).period) > wn6_half_range) return .{};

    const out: Ggto = .{
        .a0g = g.a0,
        .a1g = g.a1,
        .t0g_h = @intCast(gst.ms / time.ms_per_hour),
        .wn0g = @intCast(@mod(gst.period, wn6_modulus)),
    };
    return if (field.fits(Ggto, &ggto_rows, &out)) out else .{};
}
