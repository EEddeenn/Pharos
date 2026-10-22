const std = @import("std");
const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const field = @import("base/binary/field");
const bcnav_content = @import("domain/messages/bds/bcnav/content");
const bcnav_fields = @import("domain/messages/bds/bcnav/fields");
const ephemeris = @import("domain/messages/bds/fields/ephemeris");
const almanac = @import("domain/messages/bds/fields/almanac");
const iono = @import("domain/messages/bds/fields/ionosphere");
const time_parameters = @import("domain/messages/bds/fields/time");

const Sv = bcnav_content.Candidate;
pub const Ctx2 = struct { wn: u13, how: u8 };
pub const sf2_header = [_]field.Field(Ctx2){
    .{ .name = "wn", .width = 13, .src = .{ .field = "wn" } },
    .{ .name = "how", .width = 8, .src = .{ .field = "how" } },
};
const S = field.Field(Sv);
pub const sf2_tail = [_]S{
    .{ .name = "tgd_b2ap", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "tgd_b2ap" } },
    .{ .name = "isc_b1cd", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "isc_b1cd" } },
    .{ .name = "tgd_b1cp", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "tgd_b1cp" } },
    .{ .name = "reserved_sf2", .width = 7, .src = .reserved },
};

pub const page0 = header(0) ++ field.reservedRows(Sv, "reserved_p0", 225);
pub const page1_header = header(1) ++ bcnav_fields.sisai_oe ++ bcnav_fields.sisai_oc;
pub const page2_header = header(2) ++ bcnav_fields.sisai_oc;
pub const page3_header = header(3) ++ field.reservedRows(Sv, "reserved_p3a", 5);
pub const page4_header = header(4) ++ bcnav_fields.sisai_oc;
pub const page1_tail = field.reservedRows(field.NoSource, "reserved_p1", 27);
pub const page2_tail = field.reservedRows(field.NoSource, "reserved_p2", 30);
pub const page3_tail = field.reservedRows(field.NoSource, "reserved_p3b", 14);
pub const page4_tail = field.reservedRows(field.NoSource, "reserved_p4", 47);

fn header(comptime page: u6) [6]S {
    return .{
        .{ .name = "page_id", .width = 6, .src = .{ .constant = page } },
        .{ .name = "hs", .width = 2, .renamed = true, .src = .{ .field = "hs_b1c" } },
        .{ .name = "dif", .width = 1, .src = .{ .field = "b1c.dif" } },
        .{ .name = "sif", .width = 1, .src = .{ .field = "b1c.sif" } },
        .{ .name = "aif", .width = 1, .src = .{ .field = "b1c.aif" } },
        .{ .name = "sismai", .width = 4, .src = .{ .field = "sismai" } },
    };
}

comptime {
    std.debug.assert(field.totalWidth(Ctx2, &sf2_header) + field.totalWidth(ephemeris.Source, &(ephemeris.iodc ++ ephemeris.eph1 ++ ephemeris.eph2 ++ ephemeris.clock)) + field.totalWidth(Sv, &sf2_tail) == 576);
    std.debug.assert(field.totalWidth(Sv, &page0) == 240);
    std.debug.assert(field.totalWidth(Sv, &page1_header) + field.totalWidth(iono.Coefficients, &iono.bdgim) + field.totalWidth(time_parameters.Utc, &time_parameters.utc) + field.totalWidth(field.NoSource, &page1_tail) == 240);
    std.debug.assert(field.totalWidth(Sv, &page2_header) + field.totalWidth(almanac_epoch.Reference, &almanac_epoch.rows) + 4 * field.totalWidth(almanac.Packet, &almanac.reduced) + field.totalWidth(field.NoSource, &page2_tail) == 240);
    std.debug.assert(field.totalWidth(Sv, &page3_header) + field.totalWidth(time_parameters.Eop, &time_parameters.eop) + field.totalWidth(time_parameters.Bgto, &time_parameters.bgto) + field.totalWidth(field.NoSource, &page3_tail) == 240);
    std.debug.assert(field.totalWidth(Sv, &page4_header) + field.totalWidth(almanac.Packet, &almanac.midi) + field.totalWidth(field.NoSource, &page4_tail) == 240);
}

pub const prepared_rows = sf2_tail ++ page1_header;
pub const Codes = field.Decoded(Sv, &prepared_rows);
