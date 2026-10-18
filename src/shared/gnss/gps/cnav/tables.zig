const std = @import("std");
const schedule = @import("schedule.zig");
const field = @import("../../../codec.zig").field;
const ephemeris = @import("../ephemeris_fields.zig");
const almanac = @import("../almanac_fields.zig");
const time_parameters = @import("../time_parameters.zig");
const dc = @import("../dc.zig");
const ism = @import("../ism.zig");
const klobuchar_fields = @import("../../klobuchar_fields.zig");
const records = @import("../../records.zig");

const Sv = ephemeris.Parameters;

pub const Ctx = struct { prn: u6 = 0, tow: u17 = 0, alert: bool, isf: bool = false, phasing: bool = false };

const Type = schedule.Type;

fn messageHeader(comptime Source: type, comptime kind: Type) [5]field.Field(Source) {
    return header(Source, @backingInt(kind));
}

fn header(comptime Source: type, comptime kind: u6) [5]field.Field(Source) {
    return .{
        .{ .name = "preamble", .width = 8, .src = .{ .constant = 0x8B } },
        .{ .name = "prn", .width = 6, .src = .{ .ctx = "prn" } },
        .{ .name = "type", .width = 6, .src = .{ .constant = kind } },
        .{ .name = "tow", .width = 17, .src = .{ .ctx = "tow" } },
        .{ .name = "alert", .width = 1, .src = .{ .ctx = "alert" } },
    };
}

const S = field.Field(Sv);

pub const msg0_header = header(field.NoSource, 0);

fn tocCount(s: *const Sv) i64 {
    return s.eph.toc.msOfWeek() / records.epoch_step_ms;
}

pub const msg10 = messageHeader(Sv, .ephemeris_1) ++ [_]S{
    .{ .name = "wn", .width = 13, .src = .{ .field = "wn" } },
    .{ .name = "l1_health", .width = 1, .src = .{ .field = "l1_health" } },
    .{ .name = "l2_health", .width = 1, .src = .{ .field = "l2_health" } },
    .{ .name = "l5_health", .width = 1, .src = .{ .field = "l5_health" } },
} ++ ephemeris.top ++ ephemeris.ura_ed ++ ephemeris.toe ++ ephemeris.eph1 ++ [_]S{
    .{ .name = "integrity_status", .width = 1, .src = .{ .ctx = "isf" } },
    .{ .name = "l2c_phasing", .width = 1, .src = .{ .ctx = "phasing" } },
    .{ .name = "reserved_10", .width = 3, .src = .reserved },
};

pub const msg11 = messageHeader(Sv, .ephemeris_2) ++ ephemeris.toe ++ ephemeris.eph2 ++ [_]S{.{ .name = "reserved_11", .width = 7, .src = .reserved }};

const clock = ephemeris.top ++ ephemeris.ura_ned ++ [_]S{.{ .name = "toc", .width = 11, .src = .{ .computed_int = &tocCount } }} ++ ephemeris.af;

pub fn clockMessage(comptime kind: Type) [5 + clock.len]S {
    return messageHeader(Sv, kind) ++ clock;
}

pub const msg30_head = clockMessage(.clock_iono) ++ ephemeris.tgd ++ ephemeris.isc;
pub const msg30_tail = ephemeris.wn_op ++ [_]S{.{ .name = "reserved_30", .width = 12, .src = .reserved }};

const ggto = time_parameters.ggto_reference ++ time_parameters.ggto_id ++ time_parameters.ggto_coefficients;

pub const msg31_tail = field.reservedRows(field.NoSource, "reserved_31", 4);
pub const msg32_tail = time_parameters.eop_rows ++ field.reservedRows(time_parameters.Eop, "reserved_32", 11);
pub const msg33_tail = time_parameters.utc_rows ++ field.reservedRows(time_parameters.Utc, "reserved_33", 51);
pub const msg35_tail = ggto ++ field.reservedRows(time_parameters.Ggto, "reserved_35", 81);

pub const msg12_head = messageHeader(almanac.Reference, .reduced_almanac) ++ almanac.reference;
pub const msg12_packets = 7;
pub fn dcHead(comptime kind: Type) [5 + dc.epoch.len]field.Field(dc.Epoch) {
    return messageHeader(dc.Epoch, kind) ++ dc.epoch;
}
pub const msg13_packets = 6;
pub const msg14_packets = 2;
pub const msg34_head = clockMessage(.clock_differential_both);
pub const msg15_head = messageHeader(field.NoSource, .text);
pub const msg15_characters = 29;
pub const msg15_tail = field.reservedRows(field.NoSource, "reserved_15", 2);
pub const msg36_head = clockMessage(.clock_text);
pub const msg36_characters = 18;
pub const msg36_tail = field.reservedRows(field.NoSource, "reserved_36", 1);
pub const msg40_head = messageHeader(field.NoSource, .ism);
pub const msg40_filler = 93;

comptime {
    std.debug.assert(field.totalWidth(Sv, &msg10) == 276);
    std.debug.assert(field.totalWidth(Sv, &msg11) == 276);
    std.debug.assert(field.totalWidth(Sv, &msg30_head) + field.totalWidth(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients) + field.totalWidth(Sv, &msg30_tail) == 276);
    std.debug.assert(field.totalWidth(Sv, &clockMessage(.clock_utc)) + field.totalWidth(time_parameters.Utc, &msg33_tail) == 276);
    std.debug.assert(field.totalWidth(Sv, &clockMessage(.clock_eop)) + field.totalWidth(time_parameters.Eop, &msg32_tail) == 276);
    std.debug.assert(field.totalWidth(Sv, &clockMessage(.clock_ggto)) + field.totalWidth(time_parameters.Ggto, &msg35_tail) == 276);
    std.debug.assert(field.totalWidth(Sv, &clockMessage(.clock_reduced_almanac)) + field.totalWidth(almanac.Reference, &almanac.reference) + 4 * field.totalWidth(almanac.Packet, &almanac.reduced(6)) + field.totalWidth(field.NoSource, &msg31_tail) == 276);
    std.debug.assert(field.totalWidth(Sv, &clockMessage(.clock_midi_almanac)) + field.totalWidth(almanac.Reference, &almanac.reference) + field.totalWidth(almanac.Packet, &almanac.midi(6)) == 276);
    std.debug.assert(field.totalWidth(time_parameters.Ggto, &ggto) == 68);
    const dc_packets = field.totalWidth(dc.Packet, &dc.cdc) + field.totalWidth(dc.Packet, &dc.edc);
    std.debug.assert(field.totalWidth(almanac.Reference, &msg12_head) + msg12_packets * field.totalWidth(almanac.Packet, &almanac.reduced(6)) == 276);
    std.debug.assert(field.totalWidth(dc.Epoch, &dcHead(.clock_differential)) + msg13_packets * (1 + field.totalWidth(dc.Packet, &dc.cdc)) + 6 == 276);
    std.debug.assert(field.totalWidth(dc.Epoch, &dcHead(.ephemeris_differential)) + msg14_packets * (1 + field.totalWidth(dc.Packet, &dc.edc)) + 30 == 276);
    std.debug.assert(field.totalWidth(Sv, &msg34_head) + field.totalWidth(dc.Epoch, &dc.epoch) + 1 + dc_packets == 276);
    std.debug.assert(field.totalWidth(field.NoSource, &msg15_head) + 8 * msg15_characters + 4 + field.totalWidth(field.NoSource, &msg15_tail) == 276);
    std.debug.assert(field.totalWidth(Sv, &msg36_head) + 8 * msg36_characters + 4 + field.totalWidth(field.NoSource, &msg36_tail) == 276);
    std.debug.assert(field.totalWidth(field.NoSource, &msg40_head) + ism.parameter_bits + msg40_filler + 32 == 276);
}
