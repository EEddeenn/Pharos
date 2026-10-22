const std = @import("std");
const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const field = @import("base/binary/field");
const ephemeris = @import("domain/messages/gps/fields/ephemeris");
const almanac = @import("domain/messages/gps/fields/almanac");
const time_parameters = @import("domain/messages/gps/fields/time");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const Sv = ephemeris.Parameters;
pub const Ctx2 = struct { itow: u8, isf: bool };
pub const Ctx3 = struct { prn: u8 };
const S = field.Field(Sv);
pub const sf2 = [_]S{
    .{ .name = "wn", .width = 13, .src = .{ .field = "wn" } },
    .{ .name = "itow", .width = 8, .src = .{ .ctx = "itow" } },
} ++ ephemeris.top ++ [_]S{
    .{ .name = "l1c_health", .width = 1, .renamed = true, .src = .{ .field = "l1_health" } },
} ++ ephemeris.ura_ed ++ ephemeris.toe ++ ephemeris.eph1 ++ ephemeris.eph2 ++ ephemeris.ura_ned ++ ephemeris.af ++ ephemeris.tgd ++ ephemeris.isc_l1c ++ [_]S{
    .{ .name = "isf", .width = 1, .src = .{ .ctx = "isf" } },
} ++ ephemeris.wn_op ++ [_]S{.{ .name = "reserved_2", .width = 2, .src = .reserved }};

pub const sf3_page3_header = pageHeader(almanac_epoch.Reference, 3) ++ almanac_epoch.rows;
pub const sf3_page4_header = pageHeader(almanac_epoch.Reference, 4) ++ almanac_epoch.rows;
pub const reduced = almanac.reduced(8);
pub const midi = almanac.midi(8);
pub const ggto = time_parameters.ggto_id ++ time_parameters.ggto_reference ++ time_parameters.ggto_coefficients;
pub const sf3_page1_head = pageHeader(time_parameters.Utc, 1) ++ time_parameters.utc_rows;
pub const sf3_page1_tail = ephemeris.isc ++ [_]S{.{ .name = "reserved_p1", .width = 22, .src = .reserved }};

fn pageHeader(comptime Source: type, comptime page: u6) [2]field.Field(Source) {
    return .{
        .{ .name = "prn", .width = 8, .src = .{ .ctx = "prn" } },
        .{ .name = "page", .width = 6, .src = .{ .constant = page } },
    };
}

comptime {
    std.debug.assert(field.totalWidth(Sv, &sf2) == 576);
    std.debug.assert(field.totalWidth(time_parameters.Utc, &sf3_page1_head) + field.totalWidth(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients) + field.totalWidth(Sv, &sf3_page1_tail) == 250);
    std.debug.assert(field.totalWidth(almanac_epoch.Reference, &sf3_page3_header) + 6 * field.totalWidth(almanac.Packet, &reduced) + 17 == 250);
    std.debug.assert(field.totalWidth(almanac_epoch.Reference, &sf3_page4_header) + field.totalWidth(almanac.Packet, &midi) + 85 == 250);
    std.debug.assert(field.totalWidth(time_parameters.Ggto, &ggto) == 68);
}
