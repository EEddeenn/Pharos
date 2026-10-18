const std = @import("std");
const time = @import("shared").core.time;
const dictionary = @import("shared").core.dictionary;
const fields = @import("../fields.zig");
const record = @import("../record.zig");
const records = @import("shared").gnss.records;
const accuracy = @import("shared").gnss.accuracy;
const gps_records = @import("shared").gnss.gps.records;

const nominal_fit_interval_h = 4.0;

const Error = record.Error;

pub const Kind = enum {
    lnav,
    cnav,
    cnv2,

    /// The message types as RINEX 4 records name them.
    pub const words: std.EnumArray(Kind, []const u8) = .init(.{ .lnav = "LNAV", .cnav = "CNAV", .cnv2 = "CNV2" });
};
pub const rinex3_kind: Kind = .lnav;

pub fn kind(msg: []const u8) ?Kind {
    return dictionary.parse(Kind, msg);
}

pub fn bodyLines(k: Kind) usize {
    return switch (k) {
        .lnav => 7,
        .cnav => 8,
        .cnv2 => 9,
    };
}

pub fn complete(body: *record.Body, k: Kind, toc: time.GpsTime) Error!record.Completion {
    switch (k) {
        .lnav => {
            const iode = try record.issueOfBody(body);
            const toe = try record.toeOfBody(body);
            return completeRinex3(body, toc, iode, toe);
        },
        .cnav => return completeRinex4Cnav(body, toc, body.opt(7, 2)),
        .cnv2 => return completeRinex4Cnav2(body, toc, body.opt(8, 2)),
    }
}

fn completeRinex3(body: *record.Body, toc: time.GpsTime, iode: u16, toe: record.Toe) Error!record.Completion {
    var out: record.Completion = .{
        .toe = time.GpsTime.fromWeekMs(toe.week, toe.ms, 0),
        .toc = toc,
        .iode = iode,
        .iodc = @intCast(try fields.intField(i64, try body.get(5, 3, "iodc")) & 0xffff),
        .extra = .{ .lnav = .{
            .ura_index = if (body.opt(5, 0)) |m| accuracy.index(m) else 15,
            .health = @intCast(try fields.intField(i64, try body.get(5, 1, "health")) & 0x3f),
            .l2_codes = @intCast(try fields.intField(i64, try body.get(4, 1, "l2_codes")) & 0x3),
            .l2p_data = try body.get(4, 3, "l2p_data") != 0,
            .fit_interval = try body.get(6, 1, "fit_interval") > nominal_fit_interval_h,
        } },
    };
    body.putDelay(&out.group_delay, .tgd_l1ca, 5, 2);
    return out;
}

fn completeRinex4Cnav(body: *record.Body, toc: time.GpsTime, flags: ?f64) Error!record.Completion {
    const top = try record.sowNearReference(toc.inScale(.gps), try body.get(2, 0, "top"));
    const issue = records.issueOfEpoch(toc, .gps);
    const a_dot = try body.get(0, 0, "a_dot");
    const delta_n_dot = try body.get(4, 1, "delta_n_dot");
    const health: u32 = @intCast(try fields.intField(i64, try body.get(5, 1, "health")) & 0x7);
    var out: record.Completion = .{
        .toe = toc,
        .toc = toc,
        .top = top,
        .iode = issue,
        .iodc = issue,
        .a_dot = a_dot,
        .delta_n_dot = delta_n_dot,
        .extra = .{ .cnav = .{
            .ura = .{
                .ed = if (body.opt(5, 0)) |v| try record.clamped(i5, v) else -16,
                .ned0 = if (body.opt(4, 2)) |v| try record.clamped(i5, v) else -16,
                .ned1 = try record.clamped(u3, try body.get(4, 3, "ura_ned1")),
                .ned2 = try record.clamped(u3, try body.get(5, 3, "ura_ned2")),
            },
            .l1_health = health & 4 != 0,
            .l2_health = health & 2 != 0,
            .l5_health = health & 1 != 0,
            .flags = if (flags) |value| try cnavFlags(value) else null,
        } },
    };
    body.putDelay(&out.group_delay, .tgd_l1ca, 5, 2);
    body.putDelay(&out.group_delay, .isc_l1ca, 6, 0);
    body.putDelay(&out.group_delay, .isc_l2c, 6, 1);
    body.putDelay(&out.group_delay, .isc_l5i5, 6, 2);
    body.putDelay(&out.group_delay, .isc_l5q5, 6, 3);
    return out;
}

fn completeRinex4Cnav2(body: *record.Body, toc: time.GpsTime, flags: ?f64) Error!record.Completion {
    var out = try completeRinex4Cnav(body, toc, null);
    body.putDelay(&out.group_delay, .isc_l1cd, 7, 0);
    body.putDelay(&out.group_delay, .isc_l1cp, 7, 1);
    const c = out.extra.cnav;
    out.extra = .{
        .cnav2 = .{
            .ura = c.ura,
            .l1_health = try body.get(5, 1, "health") != 0,
            .integrity_status = if (flags) |value| try fields.intField(u32, @round(value)) & 1 != 0 else null,
        },
    };
    return out;
}

fn cnavFlags(value: f64) fields.Error!gps_records.CnavFlags {
    const bits = try fields.intField(u32, @round(value));
    return .{ .integrity_status = bits & 1 != 0, .l2c_phasing = bits & 2 != 0, .alert = bits & 4 != 0 };
}
