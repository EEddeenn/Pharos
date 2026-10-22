const scaling = @import("base/binary/scaling");
const word = @import("domain/messages/bds/d1d2/word");
const coordinates = @import("domain/earth/coordinates");
const angles = @import("base/math/angles");
pub const igp_count = 320;
pub const points_per_page = 13;
const igp_band = 160;
const igp_spacing_deg = 5.0;
const igp_band_offset_deg = 2.5;
const igp_first_lon_deg = 70.0;
const delay_codes_per_m = 8.0;
const max_delay_code = 509;
pub const points: [igp_count]coordinates.Lla = blk: {
    var out: [igp_count]coordinates.Lla = undefined;
    for (&out, 1..) |*p, n| {
        const half: f64 = if (n <= igp_band) 0 else 1;
        const k = if (n <= igp_band) n else n - igp_band;
        const column = (k - 1) / 10;
        const row = k - 10 * column;
        p.* = .{
            .lat_rad = angles.deg2rad(igp_spacing_deg * @as(f64, @floatFromInt(row)) + igp_spacing_deg - igp_band_offset_deg * half),
            .lon_rad = angles.deg2rad(igp_first_lon_deg + igp_spacing_deg * @as(f64, @floatFromInt(column))),
            .height_m = 0,
        };
    }
    break :blk out;
};

pub const Ion = struct { dtau: u9, givei: u4 };
pub const not_monitored: u9 = 510;
pub const not_available: u9 = 511;
pub const unavailable: Ion = .{ .dtau = not_available, .givei = 15 };

pub const Page = struct { pnum: u7, ions: [points_per_page]Ion };

pub fn isPage(pnum: u7) bool {
    return (pnum >= 1 and pnum <= 13) or (pnum >= 61 and pnum <= 73);
}

pub fn igpsOf(pnum: u7) struct { first: u9, count: u4 } {
    const k: u9 = if (pnum <= 13) pnum - 1 else pnum - 61;
    const base: u9 = if (pnum <= 13) 0 else igp_band;
    return .{ .first = base + 13 * k + 1, .count = if (k == 12) 4 else 13 };
}

pub fn delayCode(metres: f64) u9 {
    const q = scaling.roundWithin(metres * delay_codes_per_m, 0, max_delay_code) orelse return not_available;
    return @intCast(q);
}

pub fn encode(page: *const Page, sow_lsb: u12) word.Info {
    var out: word.Info = .{};
    var w = out.writer();
    w.writeBits(12, sow_lsb);
    w.skip(1);
    w.writeBits(7, page.pnum);
    for (page.ions[0..igpsOf(page.pnum).count]) |ion| {
        w.writeBits(9, ion.dtau);
        w.writeBits(4, ion.givei);
    }
    w.skip(word.info_bits - w.bitsWritten());
    return out;
}
