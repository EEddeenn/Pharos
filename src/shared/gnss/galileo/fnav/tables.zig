const std = @import("std");
const field = @import("../../../codec.zig").field;
const ephemeris = @import("../ephemeris_fields.zig");
const iono_fields = @import("../iono_fields.zig");
const time_parameters = @import("../time_parameters.zig");
const almanac_fields = @import("../almanac_fields.zig");

const Eph = ephemeris.Eph;
const Iono = iono_fields.Coefficients;
const Utc = time_parameters.Utc;
const Ggto = time_parameters.Ggto;
const Group = almanac_fields.Group;

pub const Ctx = ephemeris.Ctx;

const E = field.Field(Eph);
const wn: E = .{ .name = "wn", .width = 12, .src = .{ .ctx = "wn" } };
const tow: E = .{ .name = "tow", .width = 20, .src = .{ .ctx = "tow" } };

pub const page1 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 1 } },
    ephemeris.svid,
    ephemeris.iod_nav,
    ephemeris.toc,
    ephemeris.af0,
    ephemeris.af1,
    ephemeris.af2,
    ephemeris.sisa,
};
pub const page1_iono = iono_fields.rows;
pub const page1_tail = [_]E{
    ephemeris.bgd_e1e5a,
    .{ .name = "e5a_hs", .width = 2, .src = .{ .field = "extra.fnav.e5a_hs" } },
    wn,
    tow,
    .{ .name = "e5a_dvs", .width = 1, .src = .{ .field = "extra.fnav.e5a_dvs" } },
    .{ .name = "spare_1", .width = 26, .src = .reserved },
};

pub const page2 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 2 } },
    ephemeris.iod_nav,
    ephemeris.m0,
    ephemeris.omega_dot,
    ephemeris.ecc,
    ephemeris.sqrt_a,
    ephemeris.omega0,
    ephemeris.idot,
    wn,
    tow,
};
pub const page3 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 3 } },
    ephemeris.iod_nav,
    ephemeris.i0,
    ephemeris.w,
    ephemeris.delta_n,
    ephemeris.cuc,
    ephemeris.cus,
    ephemeris.crc,
    ephemeris.crs,
    ephemeris.toe,
    wn,
    tow,
    .{ .name = "spare_3", .width = 8, .src = .reserved },
};

pub const page4 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 4 } },
    ephemeris.iod_nav,
    ephemeris.cic,
    ephemeris.cis,
};
pub const page4_utc = time_parameters.utc_rows;
pub const page4_tail = [_]field.Field(Ggto){
    time_parameters.t0g_h,
    time_parameters.a0g,
    time_parameters.a1g,
    time_parameters.wn0g,
    .{ .name = "tow", .width = 20, .src = .{ .ctx = "tow" } },
    .{ .name = "spare_4", .width = 5, .src = .reserved },
};

const G = field.Field(Group);

const omega0_2 = almanac_fields.svRow(1, "omega0");

const tail_e5a: []const [:0]const u8 = &.{ "af0", "af1", "e5a_health" };

pub const page5 = [_]G{
    .{ .name = "type", .width = 6, .src = .{ .constant = 5 } },
} ++
    almanac_fields.almanac_head ++
    almanac_fields.svRows(0, almanac_fields.head) ++
    almanac_fields.svRows(0, tail_e5a) ++
    almanac_fields.svRows(1, almanac_fields.head[0..5]) ++
    [_]G{
        .{ .name = "omega0_2_msb", .width = 4, .src = .{ .part = .{ .of = &omega0_2, .shift = 12 } } },
    };

pub const page6 = [_]G{
    .{ .name = "type", .width = 6, .src = .{ .constant = 6 } },
    almanac_fields.almanac_head[0],
    .{ .name = "omega0_2_lsb", .width = 12, .src = .{ .part = .{ .of = &omega0_2, .shift = 0 } } },
} ++
    almanac_fields.svRows(1, almanac_fields.head[6..8]) ++
    almanac_fields.svRows(1, tail_e5a) ++
    almanac_fields.svRows(2, almanac_fields.head) ++
    almanac_fields.svRows(2, tail_e5a) ++
    [_]G{
        .{ .name = "spare_6", .width = 3, .src = .reserved },
    };

comptime {
    std.debug.assert(field.totalWidth(Eph, &page1) + field.totalWidth(Iono, &page1_iono) + field.totalWidth(Eph, &page1_tail) == 214);
    std.debug.assert(field.totalWidth(Eph, &page2) == 214);
    std.debug.assert(field.totalWidth(Eph, &page3) == 214);
    std.debug.assert(field.totalWidth(Eph, &page4) + field.totalWidth(Utc, &page4_utc) + field.totalWidth(Ggto, &page4_tail) == 214);
    std.debug.assert(field.totalWidth(Group, &page5) == 214);
    std.debug.assert(field.totalWidth(Group, &page6) == 214);
}
