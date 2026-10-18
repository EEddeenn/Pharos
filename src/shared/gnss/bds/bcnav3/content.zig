const std = @import("std");
const codec = @import("../../../codec.zig");
const field = codec.field;
const bcnav = @import("../bcnav.zig");
const ephemeris = @import("../ephemeris_fields.zig");
const almanac = @import("../almanac_fields.zig");
const time_parameters = @import("../time_parameters.zig");
const iono = @import("../iono_fields.zig");
const coding = @import("coding.zig");

const Sv = bcnav.Sv;

pub const Input = struct {
    sv: Sv,
    bdgim: iono.Coefficients,
    utc: ?time_parameters.Utc,
    eop: ?time_parameters.Eop,
    reference: almanac.Reference,
    alm: [6]almanac.Packet,
    bgto: time_parameters.Bgto,
};

pub const Type = enum(u6) { ephemeris = 10, clock = 30, almanac = 40 };
const Ctx = struct { sow: u20, wn: u13 };
const N = field.Field(field.NoSource);
const S = field.Field(Sv);

fn header(comptime kind: Type) [2]N {
    return .{
        .{ .name = "kind", .width = 6, .src = .{ .constant = @backingInt(kind) } },
        .{ .name = "sow", .width = 20, .src = .{ .ctx = "sow" } },
    };
}
const header10 = header(.ephemeris) ++ field.reservedRows(field.NoSource, "reserved_10", 4);
const header30 = header(.clock) ++ [_]N{.{ .name = "wn", .width = 13, .src = .{ .ctx = "wn" } }} ++ field.reservedRows(field.NoSource, "reserved_30", 4);
const header40 = header(.almanac);
const reserved40 = field.reservedRows(field.NoSource, "reserved_40", 1);

const integrity = [_]S{
    .{ .name = "dif", .width = 1, .src = .{ .field = "b2b.dif" } },
    .{ .name = "sif", .width = 1, .src = .{ .field = "b2b.sif" } },
    .{ .name = "aif", .width = 1, .src = .{ .field = "b2b.aif" } },
    .{ .name = "sismai", .width = 4, .src = .{ .field = "sismai" } },
};
const tgd = [_]S{.{ .name = "tgd_b2bi", .width = 12, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "tgd_b2bi" } }};

const accuracy = bcnav.sisai_oc ++ bcnav.sisai_oe ++ [_]S{.{ .name = "hs", .width = 2, .renamed = true, .src = .{ .field = "hs_b2b" } }};

pub fn encode(in: *const Input, kind: Type, ctx: Ctx) field.Error!coding.Message {
    var out: coding.Message = .{};
    var w = out.writer();
    switch (kind) {
        .ephemeris => {
            try field.encode(field.NoSource, &header10, &field.no_source, ctx, &w);
            try field.encode(ephemeris.Source, ephemeris.eph1[1..], &in.sv.ephemeris, ctx, &w);
            try field.encode(ephemeris.Source, &ephemeris.eph2, &in.sv.ephemeris, ctx, &w);
            try field.encode(Sv, &integrity, &in.sv, ctx, &w);
        },
        .clock => {
            try field.encode(field.NoSource, &header30, &field.no_source, ctx, &w);
            try field.encode(ephemeris.Source, &ephemeris.clock, &in.sv.ephemeris, ctx, &w);
            try field.encode(Sv, &tgd, &in.sv, ctx, &w);
            try field.encode(iono.Coefficients, &iono.bdgim, &in.bdgim, ctx, &w);
            try field.encode(time_parameters.Utc, &time_parameters.utc, &in.utc.?, ctx, &w);
            try field.encode(time_parameters.Eop, &time_parameters.eop, &in.eop.?, ctx, &w);
            try field.encode(Sv, &accuracy, &in.sv, ctx, &w);
        },
        .almanac => {
            try field.encode(field.NoSource, &header40, &field.no_source, ctx, &w);
            try field.encode(time_parameters.Bgto, &time_parameters.bgto, &in.bgto, ctx, &w);
            try field.encode(almanac.Packet, &almanac.midi, &in.alm[0], ctx, &w);
            try field.encode(almanac.Reference, &almanac.reference, &in.reference, ctx, &w);
            for (in.alm[1..]) |*reduced| try field.encode(almanac.Packet, &almanac.reduced, reduced, ctx, &w);
            try field.encode(field.NoSource, &reserved40, &field.no_source, ctx, &w);
        },
    }
    w.writeBits(24, codec.crc24q.ofBits(&out.words, coding.content_bits));
    return out;
}

comptime {
    const width = field.totalWidth;
    const n10 = width(field.NoSource, &header10) + width(ephemeris.Source, ephemeris.eph1[1..]) + width(ephemeris.Source, &ephemeris.eph2) + width(Sv, &integrity);
    const n30 = width(field.NoSource, &header30) + width(ephemeris.Source, &ephemeris.clock) + width(Sv, &tgd) + width(iono.Coefficients, &iono.bdgim) + width(time_parameters.Utc, &time_parameters.utc) + width(time_parameters.Eop, &time_parameters.eop) + width(Sv, &accuracy);
    const n40 = width(field.NoSource, &header40) + width(time_parameters.Bgto, &time_parameters.bgto) + width(almanac.Packet, &almanac.midi) + width(almanac.Reference, &almanac.reference) + 5 * width(almanac.Packet, &almanac.reduced) + width(field.NoSource, &reserved40);
    for (.{ n10, n30, n40 }) |n| std.debug.assert(n == coding.content_bits);
}
