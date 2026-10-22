const std = @import("std");
const time = @import("domain/time/gps");
const dictionary = @import("base/text/dictionary");
const record = @import("products/pack/input/navigation/records/decode");
const records = @import("domain/navigation/records");
const accuracy = @import("domain/navigation/accuracy");
const gps_records = @import("domain/navigation/records/gps");

const Error = record.Error;

const nominal_fit_interval_h = 4.0;

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
            const iode = try body.integer(u8, 0, 0, "iode");
            const toe = try record.toeOfBody(body);
            return completeRinex3(body, toc, iode, toe);
        },
        .cnav => return completeRinex4Cnav(body, toc, try body.optionalInteger(u3, 7, 2, "flags")),
        .cnv2 => return completeRinex4Cnav2(body, toc, try body.optionalInteger(u1, 8, 2, "integrity_status")),
    }
}

fn completeRinex3(body: *record.Body, toc: time.GpsTime, iode: u16, toe: record.Toe) Error!record.Completion {
    var out: record.Completion = .{
        .toe = time.GpsTime.fromWeekMs(toe.week, toe.ms, 0),
        .toc = toc,
        .iode = iode,
        .iodc = try body.integer(u10, 5, 3, "iodc"),
        .extra = .{ .lnav = .{
            .ura_index = if (body.opt(5, 0)) |m| accuracy.index(m) else 15,
            .health = try body.integer(u6, 5, 1, "health"),
            .l2_codes = try body.integer(u2, 4, 1, "l2_codes"),
            .l2p_data = try body.integer(u1, 4, 3, "l2p_data") != 0,
            .fit_interval = try body.get(6, 1, "fit_interval") > nominal_fit_interval_h,
        } },
    };
    body.putDelay(&out.group_delay, .tgd_l1ca, 5, 2);
    return out;
}

fn completeRinex4Cnav(body: *record.Body, toc: time.GpsTime, flags: ?u3) Error!record.Completion {
    const top = try record.sowNearReference(toc.inScale(.gps), try body.get(2, 0, "top"));
    const issue = records.issueOfEpoch(toc, .gps);
    const a_dot = try body.get(0, 0, "a_dot");
    const delta_n_dot = try body.get(4, 1, "delta_n_dot");
    const health = try body.integer(u3, 5, 1, "health");
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
                .ed = try body.optionalInteger(i5, 5, 0, "ura_ed") orelse 15,
                .ned0 = try body.optionalInteger(i5, 4, 2, "ura_ned0") orelse 15,
                .ned1 = try body.integer(u3, 4, 3, "ura_ned1"),
                .ned2 = try body.integer(u3, 5, 3, "ura_ned2"),
            },
            .l1_health = health & 4 != 0,
            .l2_health = health & 2 != 0,
            .l5_health = health & 1 != 0,
            .flags = if (flags) |value| cnavFlags(value) else null,
        } },
    };
    body.putDelay(&out.group_delay, .tgd_l1ca, 5, 2);
    body.putDelay(&out.group_delay, .isc_l1ca, 6, 0);
    body.putDelay(&out.group_delay, .isc_l2c, 6, 1);
    body.putDelay(&out.group_delay, .isc_l5i5, 6, 2);
    body.putDelay(&out.group_delay, .isc_l5q5, 6, 3);
    return out;
}

fn completeRinex4Cnav2(body: *record.Body, toc: time.GpsTime, flags: ?u1) Error!record.Completion {
    var out = try completeRinex4Cnav(body, toc, null);
    body.putDelay(&out.group_delay, .isc_l1cd, 7, 0);
    body.putDelay(&out.group_delay, .isc_l1cp, 7, 1);
    const c = out.extra.cnav;
    out.extra = .{
        .cnav2 = .{
            .ura = c.ura,
            .l1_health = try body.integer(u1, 5, 1, "health") != 0,
            .integrity_status = if (flags) |value| value != 0 else null,
        },
    };
    return out;
}

fn cnavFlags(bits: u3) gps_records.CnavFlags {
    return .{ .integrity_status = bits & 1 != 0, .l2c_phasing = bits & 2 != 0, .alert = bits & 4 != 0 };
}
