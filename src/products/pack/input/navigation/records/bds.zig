const std = @import("std");
const time = @import("domain/time/gps");
const dictionary = @import("base/text/dictionary");
const record = @import("products/pack/input/navigation/records/decode");
const records = @import("domain/navigation/records");
const accuracy = @import("domain/navigation/accuracy");
const bds_records = @import("domain/navigation/records/bds");

const Error = record.Error;

pub const Kind = enum {
    d1,
    d2,
    cnv1,
    cnv2,
    cnv3,

    /// The message types as RINEX 4 records name them.
    pub const words: std.EnumArray(Kind, []const u8) = .init(.{ .d1 = "D1", .d2 = "D2", .cnv1 = "CNV1", .cnv2 = "CNV2", .cnv3 = "CNV3" });
};
pub const rinex3_kind: Kind = .d1;

const Bcnav = enum { cnv1, cnv2, cnv3 };

pub fn kind(msg: []const u8) ?Kind {
    return dictionary.parse(Kind, msg);
}

pub fn bodyLines(k: Kind) usize {
    return switch (k) {
        .d1, .d2 => 7,
        .cnv1, .cnv2 => 9,
        .cnv3 => 8,
    };
}

pub fn complete(body: *record.Body, k: Kind, toc: time.GpsTime) Error!record.Completion {
    switch (k) {
        .d1, .d2 => {
            const iode = try body.integer(u5, 0, 0, "aode");
            const toe = try record.toeOfBody(body);
            return completeRinex3(body, toc, iode, toe);
        },
        .cnv1 => return completeRinex4Bcnav(body, .cnv1, toc),
        .cnv2 => return completeRinex4Bcnav(body, .cnv2, toc),
        .cnv3 => return completeRinex4Bcnav(body, .cnv3, toc),
    }
}

fn completeRinex3(body: *record.Body, toc: time.GpsTime, iode: u16, toe: record.Toe) Error!record.Completion {
    const iodc = try body.integer(u5, 6, 1, "aodc");
    var out: record.Completion = .{
        .toe = time.GpsTime.fromScaleWeekMs(.bds, toe.week, toe.ms, 0),
        .toc = toc.addMs(time.bds_offset_ms),
        .iode = iode,
        .iodc = iodc,
        .extra = .{ .d1d2 = .{
            .ura_index = if (body.opt(5, 0)) |m| accuracy.index(m) else 15,
            .sat_h1 = try body.integer(u1, 5, 1, "sat_h1") != 0,
            .aodc = iodc,
            .aode = @intCast(iode),
        } },
    };
    body.putDelay(&out.group_delay, .tgd_b1i, 5, 2);
    body.putDelay(&out.group_delay, .tgd_b2i, 5, 3);
    return out;
}

fn completeRinex4Bcnav(body: *record.Body, k: Bcnav, toc_calendar: time.GpsTime) Error!record.Completion {
    const toc = toc_calendar.addMs(time.bds_offset_ms);
    const st = toc.inScale(.bds);
    const toe = try record.sowNearReference(st, try body.get(2, 0, "toe"));
    const top = try record.sowNearReference(st, try body.get(4, 3, "top"));
    const a_dot = try body.get(0, 0, "a_dot");
    const delta_n_dot = try body.get(4, 1, "delta_n_dot");
    const status: usize = if (k == .cnv3) 6 else 7;
    var delays = records.GroupDelays.init(.{});
    var iode: u16 = undefined;
    var iodc: u16 = undefined;
    if (k == .cnv3) {
        iode = records.issueOfEpoch(toe, .bds);
        iodc = iode;
        body.putDelay(&delays, .tgd_b2bi, status, 3);
    } else {
        iode = try body.integer(u8, 8, 3, "iode");
        iodc = try body.integer(u10, status, 3, "iodc");
        body.putDelay(&delays, .tgd_b1cp, 6, 2);
        body.putDelay(&delays, .tgd_b2ap, 6, 3);
        if (k == .cnv1) body.putDelay(&delays, .isc_b1cd, 6, 0) else body.putDelay(&delays, .isc_b2ad, 6, 1);
    }
    const unhealthy = try body.integer(u1, status, 1, "health") != 0;
    const flag_word = try body.get(status, 2, "integrity_flags");
    const flags: u6 = if (k == .cnv2) try body.integerValue(u6, flag_word, "integrity_flags") else try body.integerValue(u3, flag_word, "integrity_flags");
    const sat_type = std.enums.fromInt(bds_records.SatType, try body.integer(u2, 4, 2, "sat_type")) orelse {
        body.failure = .out_of_range;
        return error.MalformedRecord;
    };
    const extra: bds_records.BcnavExtra = .{
        .sat_type = sat_type,
        .sismai = try record.bitsOf(u4, body, status, 0, "sismai"),
        .sisai_oe = try record.bitsOf(u5, body, 5, 0, "sisai_oe"),
        .sisai_ocb = try record.bitsOf(u5, body, 5, 1, "sisai_ocb"),
        .sisai_oc1 = try record.bitsOf(u3, body, 5, 2, "sisai_oc1"),
        .sisai_oc2 = try record.bitsOf(u3, body, 5, 3, "sisai_oc2"),
        .b1c = if (k != .cnv3) signalFlags(flags) else null,
        .b2a = if (k == .cnv2) signalFlags(flags >> 3) else null,
        .b2b = if (k == .cnv3) signalFlags(flags) else null,
        .hs_b1c = k == .cnv1 and unhealthy,
        .hs_b2a = k == .cnv2 and unhealthy,
        .hs_b2b = k == .cnv3 and unhealthy,
    };
    return .{
        .toe = toe,
        .toc = toc,
        .top = top,
        .iode = iode,
        .iodc = iodc,
        .a_dot = a_dot,
        .delta_n_dot = delta_n_dot,
        .group_delay = delays,
        .extra = switch (k) {
            .cnv1 => .{ .bcnav1 = extra },
            .cnv2 => .{ .bcnav2 = extra },
            .cnv3 => .{ .bcnav3 = extra },
        },
    };
}

fn signalFlags(n: u6) bds_records.BcnavSignalFlags {
    return .{ .dif = n & 4 != 0, .sif = n & 2 != 0, .aif = n & 1 != 0 };
}
