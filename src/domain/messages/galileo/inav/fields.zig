const std = @import("std");
const nequick = @import("domain/propagation/ionosphere/nequick");
const field = @import("base/binary/field");
const ephemeris_fields = @import("domain/messages/galileo/fields/ephemeris");
const iono_fields = @import("domain/messages/galileo/fields/ionosphere");
const time_parameters = @import("domain/messages/galileo/fields/time");
const Parameters = @import("domain/messages/galileo/inav/content").Parameters;
const NoSource = field.NoSource;
const Iono = nequick.Coefficients;
const Utc = time_parameters.Utc;
const ephemeris = ephemeris_fields.Fields(Parameters);
pub const Ctx = ephemeris_fields.Ctx;
const E = field.Field(Parameters);
pub const word1 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 1 } },
    ephemeris.iod_nav,
    ephemeris.toe,
    ephemeris.m0,
    ephemeris.ecc,
    ephemeris.sqrt_a,
    .{ .name = "spare_1", .width = 2, .src = .reserved },
};
pub const word2 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 2 } },
    ephemeris.iod_nav,
    ephemeris.omega0,
    ephemeris.i0,
    ephemeris.w,
    ephemeris.idot,
    .{ .name = "spare_2", .width = 2, .src = .reserved },
};
pub const word3 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 3 } },
    ephemeris.iod_nav,
    ephemeris.omega_dot,
    ephemeris.delta_n,
    ephemeris.cuc,
    ephemeris.cus,
    ephemeris.crc,
    ephemeris.crs,
    ephemeris.sisa,
};
pub const word4 = [_]E{
    .{ .name = "type", .width = 6, .src = .{ .constant = 4 } },
    ephemeris.iod_nav,
    ephemeris.svid,
    ephemeris.cic,
    ephemeris.cis,
    ephemeris.toc,
    ephemeris.af0,
    ephemeris.af1,
    ephemeris.af2,
    .{ .name = "spare_4", .width = 2, .src = .reserved },
};

pub const word5_iono = [_]field.Field(Iono){.{ .name = "type", .width = 6, .src = .{ .constant = 5 } }} ++ iono_fields.rows;
pub const word5 = [_]E{
    ephemeris.bgd_e1e5a,
    ephemeris.bgd_e1e5b,
    .{ .name = "e5b_hs", .width = 2, .src = .{ .field = "e5b_hs" } },
    .{ .name = "e1b_hs", .width = 2, .src = .{ .field = "e1b_hs" } },
    .{ .name = "e5b_dvs", .width = 1, .src = .{ .field = "e5b_dvs" } },
    .{ .name = "e1b_dvs", .width = 1, .src = .{ .field = "e1b_dvs" } },
    .{ .name = "wn", .width = 12, .src = .{ .ctx = "wn" } },
    .{ .name = "tow", .width = 20, .src = .{ .ctx = "tow" } },
    .{ .name = "spare_5", .width = 23, .src = .reserved },
};

const U = field.Field(Utc);
pub const word6 = [_]U{.{ .name = "type", .width = 6, .src = .{ .constant = 6 } }} ++ time_parameters.utc_rows ++ [_]U{
    .{ .name = "tow", .width = 20, .src = .{ .ctx = "tow" } },
    .{ .name = "spare_6", .width = 3, .src = .reserved },
};

const N = field.Field(NoSource);
pub const word0 = [_]N{
    .{ .name = "type", .width = 6, .src = .{ .constant = 0 } },
    .{ .name = "time", .width = 2, .src = .{ .constant = 2 } },
    .{ .name = "spare_0a", .width = 56, .src = .reserved },
    .{ .name = "spare_0b", .width = 32, .src = .reserved },
    .{ .name = "wn", .width = 12, .src = .{ .ctx = "wn" } },
    .{ .name = "tow", .width = 20, .src = .{ .ctx = "tow" } },
};

comptime {
    for (.{ word1, word2, word3, word4 }) |layout| std.debug.assert(field.totalWidth(Parameters, &layout) == 128);
    std.debug.assert(field.totalWidth(Iono, &word5_iono) + field.totalWidth(Parameters, &word5) == 128);
    std.debug.assert(field.totalWidth(Utc, &word6) == 128);
    std.debug.assert(field.totalWidth(NoSource, &word0) == 128);
}
