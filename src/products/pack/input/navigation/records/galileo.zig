const std = @import("std");
const time = @import("domain/time/gps");
const dictionary = @import("base/text/dictionary");
const record = @import("products/pack/input/navigation/records/decode");
const galileo_records = @import("domain/navigation/records/galileo");

const Error = record.Error;

pub const Kind = enum {
    inav,
    fnav,

    /// The message types as RINEX 4 records name them.
    pub const words: std.EnumArray(Kind, []const u8) = .init(.{ .inav = "INAV", .fnav = "FNAV" });
};
pub const rinex3_kind: Kind = .inav;

pub fn kind(msg: []const u8) ?Kind {
    return dictionary.parse(Kind, msg);
}

pub fn bodyLines(_: Kind) usize {
    return 7;
}

pub fn complete(body: *record.Body, _: Kind, toc: time.GpsTime) Error!record.Completion {
    const iode = try body.integer(u10, 0, 0, "iode");
    const toe = try record.toeOfBody(body);
    const sources = try body.integer(u10, 4, 1, "data_sources");
    const health = try body.integer(u9, 5, 1, "health");
    const sisa = if (body.opt(5, 0)) |m| galileo_records.sisaIndex(m) else galileo_records.sisa_napa;
    var out: record.Completion = .{
        .toe = time.GpsTime.fromWeekMs(toe.week, toe.ms, 0),
        .toc = toc,
        .iode = iode,
        .iodc = iode,
        .extra = if (sources & 0x2 != 0) .{ .fnav = .{
            .sisa_index = sisa,
            .iod_nav = iode,
            .e5a_hs = @intCast((health >> 4) & 0x3),
            .e5a_dvs = health & 0x8 != 0,
        } } else .{ .inav = .{
            .sisa_index = sisa,
            .iod_nav = iode,
            .e1b_hs = @intCast((health >> 1) & 0x3),
            .e5b_hs = @intCast((health >> 7) & 0x3),
            .e1b_dvs = health & 0x1 != 0,
            .e5b_dvs = health & 0x40 != 0,
        } },
    };
    body.putDelay(&out.group_delay, .bgd_e1e5a, 5, 2);
    if (sources & 0x2 == 0) body.putDelay(&out.group_delay, .bgd_e1e5b, 5, 3);
    return out;
}
