const std = @import("std");
const crc = @import("base/binary/crc");
const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const field = @import("base/binary/field");
const bcnav_content = @import("domain/messages/bds/bcnav/content");
const bcnav_fields = @import("domain/messages/bds/bcnav/fields");
const ephemeris = @import("domain/messages/bds/fields/ephemeris");
const almanac = @import("domain/messages/bds/fields/almanac");
const time_parameters = @import("domain/messages/bds/fields/time");
const iono = @import("domain/messages/bds/fields/ionosphere");
const b2b = @import("domain/messages/bds/b2b_frame");
const Sv = bcnav_content.Candidate;
pub const Input = struct {
    sv: bcnav_content.Sv,
    bdgim: iono.Codes,
    utc: time_parameters.UtcCodes,
    eop: time_parameters.EopCodes,
    reference: almanac_epoch.Reference,
    alm: [6]almanac.Packet,
    bgto: time_parameters.BgtoCodes,
};

pub const Type = enum(u6) { ephemeris = 10, clock = 30, almanac = 40 };
const Ctx = struct { sow: u20, wn: u13 };
const N = field.Field(field.NoSource);
const S = field.Field(Sv);
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
const accuracy = bcnav_fields.sisai_oc ++ bcnav_fields.sisai_oe ++ [_]S{.{ .name = "hs", .width = 2, .renamed = true, .src = .{ .field = "hs_b2b" } }};

pub const prepared_rows = integrity ++ tgd ++ accuracy;
pub const Codes = field.Decoded(Sv, &prepared_rows);

pub fn encode(in: *const Input, kind: Type, ctx: Ctx) field.Error!b2b.Message {
    var out: b2b.Message = .{};
    var w = out.writer();
    switch (kind) {
        .ephemeris => {
            try field.encode(field.NoSource, &header10, &field.no_source, ctx, &w);
            field.writeDecoded(ephemeris.Source, ephemeris.eph1[1..], in.sv.ephemeris.codes, &w);
            field.writeDecoded(ephemeris.Source, &ephemeris.eph2, in.sv.ephemeris.codes, &w);
            field.writeDecoded(Sv, &integrity, in.sv.codes.bcnav3, &w);
        },
        .clock => {
            try field.encode(field.NoSource, &header30, &field.no_source, ctx, &w);
            field.writeDecoded(ephemeris.Source, &ephemeris.clock, in.sv.ephemeris.codes, &w);
            field.writeDecoded(Sv, &tgd, in.sv.codes.bcnav3, &w);
            field.writeDecoded(iono.Coefficients, &iono.bdgim, in.bdgim, &w);
            field.writeDecoded(time_parameters.Utc, &time_parameters.utc, in.utc, &w);
            field.writeDecoded(time_parameters.Eop, &time_parameters.eop, in.eop, &w);
            field.writeDecoded(Sv, &accuracy, in.sv.codes.bcnav3, &w);
        },
        .almanac => {
            try field.encode(field.NoSource, &header40, &field.no_source, ctx, &w);
            field.writeDecoded(time_parameters.Bgto, &time_parameters.bgto, in.bgto, &w);
            try field.encode(almanac.Packet, &almanac.midi, &in.alm[0], ctx, &w);
            try field.encode(almanac_epoch.Reference, &almanac_epoch.rows, &in.reference, ctx, &w);
            for (in.alm[1..]) |*reduced| try field.encode(almanac.Packet, &almanac.reduced, reduced, ctx, &w);
            try field.encode(field.NoSource, &reserved40, &field.no_source, ctx, &w);
        },
    }
    w.writeBits(24, crc.crc24q.ofBits(&out.words, b2b.content_bits));
    return out;
}

fn header(comptime kind: Type) [2]N {
    return .{
        .{ .name = "kind", .width = 6, .src = .{ .constant = @backingInt(kind) } },
        .{ .name = "sow", .width = 20, .src = .{ .ctx = "sow" } },
    };
}

comptime {
    const width = field.totalWidth;
    const n10 = width(field.NoSource, &header10) + width(ephemeris.Source, ephemeris.eph1[1..]) + width(ephemeris.Source, &ephemeris.eph2) + width(Sv, &integrity);
    const n30 = width(field.NoSource, &header30) + width(ephemeris.Source, &ephemeris.clock) + width(Sv, &tgd) + width(iono.Coefficients, &iono.bdgim) + width(time_parameters.Utc, &time_parameters.utc) + width(time_parameters.Eop, &time_parameters.eop) + width(Sv, &accuracy);
    const n40 = width(field.NoSource, &header40) + width(time_parameters.Bgto, &time_parameters.bgto) + width(almanac.Packet, &almanac.midi) + width(almanac_epoch.Reference, &almanac_epoch.rows) + 5 * width(almanac.Packet, &almanac.reduced) + width(field.NoSource, &reserved40);
    for (.{ n10, n30, n40 }) |n| std.debug.assert(n == b2b.content_bits);
}
