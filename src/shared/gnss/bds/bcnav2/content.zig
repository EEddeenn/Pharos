const std = @import("std");
const field = @import("../../../codec.zig").field;
const bitwriter = @import("../../../codec.zig").bitwriter;
const ephemeris = @import("../ephemeris_fields.zig");
const almanac = @import("../almanac_fields.zig");
const time_parameters = @import("../time_parameters.zig");
const iono = @import("../iono_fields.zig");
const bcnav = @import("../bcnav.zig");
const Sv = bcnav.Sv;

pub const Type = enum(u6) { ephemeris_1 = 10, ephemeris_2 = 11, clock_iono = 30, clock_reduced_almanac = 31, clock_eop = 32, clock_bgto = 33, clock_utc = 34, midi_almanac = 40 };
const Ctx = struct { prn: u6, kind: Type, sow: u18, wn: u13 };
const Input = struct {
    reference: almanac.Reference,
    alm: [3]almanac.Packet,
    bdgim: iono.Coefficients,
    utc: ?time_parameters.Utc,
    eop: ?time_parameters.Eop,
    bgto: time_parameters.Bgto,
};

const H = field.Field(field.NoSource);
const header = [_]H{
    .{ .name = "prn", .width = 6, .src = .{ .ctx = "prn" } },
    .{ .name = "kind", .width = 6, .src = .{ .ctx = "kind" } },
    .{ .name = "sow", .width = 18, .src = .{ .ctx = "sow" } },
};
const week = [_]H{.{ .name = "wn", .width = 13, .src = .{ .ctx = "wn" } }};
const reserved30 = field.reservedRows(field.NoSource, "reserved_30", 33);
const reserved31 = field.reservedRows(field.NoSource, "reserved_31", 8);
const reserved32 = field.reservedRows(field.NoSource, "reserved_32", 5);
const reserved33 = field.reservedRows(field.NoSource, "reserved_33", 16);
const reserved34 = field.reservedRows(field.NoSource, "reserved_34", 24);
const reserved40 = field.reservedRows(field.NoSource, "reserved_40", 39);
const S = field.Field(Sv);
const flags = [_]S{
    .{ .name = "dif", .width = 1, .src = .{ .field = "b2a.dif" } },
    .{ .name = "sif", .width = 1, .src = .{ .field = "b2a.sif" } },
    .{ .name = "aif", .width = 1, .src = .{ .field = "b2a.aif" } },
    .{ .name = "sismai", .width = 4, .src = .{ .field = "sismai" } },
    .{ .name = "dif_b1c", .width = 1, .renamed = true, .src = .{ .field = "b1c.dif" } },
    .{ .name = "sif_b1c", .width = 1, .renamed = true, .src = .{ .field = "b1c.sif" } },
    .{ .name = "aif_b1c", .width = 1, .renamed = true, .src = .{ .field = "b1c.aif" } },
};
const hs_flags = [_]S{.{ .name = "hs", .width = 2, .renamed = true, .src = .{ .field = "hs_b2a" } }} ++ flags;
const clock_iodc = ephemeris.clock ++ ephemeris.iodc;
const delays = [_]S{
    .{ .name = "tgd_b2ap", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "tgd_b2ap" } },
    .{ .name = "isc_b2ad", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "isc_b2ad" } },
    .{ .name = "tgd_b1cp", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "tgd_b1cp" } },
};

pub fn encode(sv: *const Sv, a: Input, ctx: Ctx, w: *bitwriter.BitWriter) field.Error!void {
    try field.encode(field.NoSource, &header, &field.no_source, .{ .prn = ctx.prn, .kind = @backingInt(ctx.kind), .sow = ctx.sow }, w);
    if (ctx.kind != .ephemeris_1) try field.encode(Sv, &hs_flags, sv, .{}, w);
    switch (ctx.kind) {
        .ephemeris_1 => {
            try field.encode(field.NoSource, &week, &field.no_source, ctx, w);
            try field.encode(Sv, &flags, sv, .{}, w);
            try field.encode(ephemeris.Source, &ephemeris.eph1, &sv.ephemeris, .{}, w);
        },
        .ephemeris_2 => try field.encode(ephemeris.Source, &ephemeris.eph2, &sv.ephemeris, .{}, w),
        .clock_iono => {
            try field.encode(ephemeris.Source, &clock_iodc, &sv.ephemeris, .{}, w);
            try field.encode(Sv, delays[0..2], sv, .{}, w);
            try field.encode(iono.Coefficients, &iono.bdgim, &a.bdgim, .{}, w);
            try field.encode(Sv, delays[2..3], sv, .{}, w);
            try field.encode(field.NoSource, &reserved30, &field.no_source, ctx, w);
        },
        .clock_reduced_almanac => {
            try field.encode(ephemeris.Source, &clock_iodc, &sv.ephemeris, .{}, w);
            try field.encode(almanac.Reference, &almanac.reference, &a.reference, .{}, w);
            for (&a.alm) |*packet| try field.encode(almanac.Packet, &almanac.reduced, packet, .{}, w);
            try field.encode(field.NoSource, &reserved31, &field.no_source, ctx, w);
        },
        .clock_eop => {
            try field.encode(ephemeris.Source, &clock_iodc, &sv.ephemeris, .{}, w);
            try field.encode(time_parameters.Eop, &time_parameters.eop, &a.eop.?, .{}, w);
            try field.encode(field.NoSource, &reserved32, &field.no_source, ctx, w);
        },
        .clock_bgto => {
            try field.encode(ephemeris.Source, &ephemeris.clock, &sv.ephemeris, .{}, w);
            try field.encode(time_parameters.Bgto, &time_parameters.bgto, &a.bgto, .{}, w);
            try field.encode(almanac.Packet, &almanac.reduced, &a.alm[0], .{}, w);
            try field.encode(ephemeris.Source, &ephemeris.iodc, &sv.ephemeris, .{}, w);
            try field.encode(almanac.Reference, &almanac.reference, &a.reference, .{}, w);
            try field.encode(field.NoSource, &reserved33, &field.no_source, ctx, w);
        },
        .clock_utc => {
            try field.encode(Sv, &bcnav.sisai_oc, sv, .{}, w);
            try field.encode(ephemeris.Source, &clock_iodc, &sv.ephemeris, .{}, w);
            try field.encode(time_parameters.Utc, &time_parameters.utc, &a.utc.?, .{}, w);
            try field.encode(field.NoSource, &reserved34, &field.no_source, ctx, w);
        },
        .midi_almanac => {
            try field.encode(Sv, &bcnav.sisai_oe, sv, .{}, w);
            try field.encode(Sv, &bcnav.sisai_oc, sv, .{}, w);
            try field.encode(almanac.Packet, &almanac.midi, &a.alm[0], .{}, w);
            try field.encode(field.NoSource, &reserved40, &field.no_source, ctx, w);
        },
    }
}

comptime {
    const width = field.totalWidth;
    const prefix = width(field.NoSource, &header) + width(Sv, &hs_flags);
    const clock = width(ephemeris.Source, &ephemeris.clock);
    const iodc = width(ephemeris.Source, &ephemeris.iodc);
    const reference = width(almanac.Reference, &almanac.reference);
    const reduced = width(almanac.Packet, &almanac.reduced);
    const n10 = width(field.NoSource, &header) + width(field.NoSource, &week) + width(Sv, &flags) + width(ephemeris.Source, &ephemeris.eph1);
    const n11 = prefix + width(ephemeris.Source, &ephemeris.eph2);
    const n30 = prefix + clock + iodc + width(Sv, &delays) + width(iono.Coefficients, &iono.bdgim) + width(field.NoSource, &reserved30);
    const n31 = prefix + clock + iodc + reference + 3 * reduced + width(field.NoSource, &reserved31);
    const n32 = prefix + clock + iodc + width(time_parameters.Eop, &time_parameters.eop) + width(field.NoSource, &reserved32);
    const n33 = prefix + clock + width(time_parameters.Bgto, &time_parameters.bgto) + reduced + iodc + reference + width(field.NoSource, &reserved33);
    const n34 = prefix + width(Sv, &bcnav.sisai_oc) + clock + iodc + width(time_parameters.Utc, &time_parameters.utc) + width(field.NoSource, &reserved34);
    const n40 = prefix + width(Sv, &bcnav.sisai_oe) + width(Sv, &bcnav.sisai_oc) + width(almanac.Packet, &almanac.midi) + width(field.NoSource, &reserved40);
    for (.{ n10, n11, n30, n31, n32, n33, n34, n40 }) |n| std.debug.assert(n == 264);
}
