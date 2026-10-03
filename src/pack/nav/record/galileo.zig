const std = @import("std");
const time = @import("shared").core.time;
const gnss = @import("shared").gnss;
const fields = @import("../fields.zig");
const record = @import("../record.zig");
const galileo = gnss.galileo.records;

const Error = record.Error;

pub const Kind = enum { inav, fnav };
pub const rinex3_kind: Kind = .inav;

pub fn kind(msg: []const u8) ?Kind {
    const kinds = std.StaticStringMap(Kind).initComptime(.{ .{ "INAV", .inav }, .{ "FNAV", .fnav } });
    return kinds.get(msg);
}

pub fn bodyLines(_: Kind) usize {
    return 7;
}

pub fn complete(body: *record.Body, _: Kind, toc: time.GpsTime) Error!record.Completion {
    const iode = try record.issueOfBody(body);
    const toe = try record.toeOfBody(body);
    const sources: u16 = @intCast(try fields.intField(i64, try body.get(4, 1, "data_sources")) & 0x3ff);
    const health: u16 = @intCast(try fields.intField(i64, try body.get(5, 1, "health")) & 0x1ff);
    const sisa = if (body.opt(5, 0)) |m| galileo.sisaIndex(m) else galileo.sisa_napa;
    var out: record.Completion = .{
        .toe = time.GpsTime.fromWeekMs(toe.week, toe.ms, 0),
        .toc = toc,
        .iode = iode,
        .iodc = iode,
        .extra = if (sources & 0x2 != 0) .{ .fnav = .{
            .sisa_index = sisa,
            .iod_nav = @intCast(iode & 0x3ff),
            .e5a_hs = @intCast((health >> 4) & 0x3),
            .e5a_dvs = health & 0x8 != 0,
        } } else .{ .inav = .{
            .sisa_index = sisa,
            .iod_nav = @intCast(iode & 0x3ff),
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
