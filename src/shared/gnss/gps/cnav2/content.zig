const std = @import("std");
const time = @import("../../../core.zig").time;
const field = @import("../../../codec.zig").field;
const frame = @import("../../../codec.zig").frame;
const crc24q = @import("../../../codec.zig").crc24q;
const klobuchar_fields = @import("../../klobuchar_fields.zig");
const cnvx = @import("../cnvx.zig");
const Parameters = @import("../ephemeris_fields.zig").Parameters;
const dc = @import("../dc.zig");
const messages = @import("../messages.zig");
const text = @import("../text.zig");
const tables = @import("tables.zig");
const pages = @import("pages.zig");
const publications = @import("publications.zig");
const time_parameters = @import("../time_parameters.zig");
const almanac_fields = @import("../almanac_fields.zig");

const GpsTime = time.GpsTime;
pub const frame_ms = 18_000;
const Sf2 = frame.Bits(600);
const Sf3 = frame.Bits(274);
const Error = field.Error;
const Page = union(enum) {
    utc,
    eop: i64,
    reduced: i64,
    midi: u6,
    dc: struct { epoch: dc.Epoch, packet: dc.Packet },
    text: text.Page(pages.text_length),
    configuration: *const publications.Payload,
    ism: *const publications.Payload,
};

pub const Set = struct {
    data: cnvx.Data,
    publications: []const publications.PreparedPublication = &.{},
    configuration: ?*const publications.Payload = null,
    dc: ?dc.Source = null,

    pub const Inputs = struct {
        shared: cnvx.Inputs,
        publications: []const publications.PreparedPublication = &.{},
        configuration: ?*const publications.Payload = null,
        dc: ?dc.Source = null,
    };

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.* = .{ .data = undefined, .publications = in.publications, .configuration = in.configuration, .dc = in.dc };
        set.data.build(.cnav2, in.shared);
        try set.validate();
    }

    fn validate(set: *const Set) Error!void {
        const data = &set.data;
        if (data.utc == null) return;
        for (&data.sv) |*entry| {
            const sv = if (entry.*) |*sv| sv else continue;
            if (sv.value() == null) continue;
            if (!field.fits(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, &data.klobuchar)) return error.FieldOverflow;
            return;
        }
    }

    fn contentAt(self: *const Set, t: GpsTime) ?*const publications.Content {
        const publication = publications.PreparedPublication.at(self.publications, t) orelse return null;
        return &publication.content;
    }

    pub fn isfAt(self: *const Set, sv: *const cnvx.Content, t: GpsTime) ?bool {
        const content = self.contentAt(t);
        return cnvx.cnav2Isf(sv, if (content) |c| c.sources.integrity else null);
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.data.hasRecord(prn);
    }
};

const sf2_data_bits = 576;
const sf3_data_bits = 250;
const reduced_packets = 6;
const reduced_packets_end = 233;

pub fn subframe2Bits(sv: *const cnvx.Content, itow: u8, isf: ?bool) Error!Sf2 {
    var out: Sf2 = .{};
    var w = out.writer();
    if (isf) |status| {
        try field.encode(Parameters, &tables.sf2, sv.value().?, tables.Ctx2{ .itow = itow, .isf = status }, &w);
    } else {
        w.writeAlternating(sf2_data_bits);
    }
    w.writeBits(24, crc24q.ofBits(&out.words, sf2_data_bits));
    return out;
}

pub fn subframe3Bits(set: *const Set, prn: u8, page: Page) Error!Sf3 {
    const data = &set.data;
    var out: Sf3 = .{};
    var w = out.writer();
    switch (page) {
        .utc => {
            const sv = &data.sv[prn - 1].?;
            const parameters = sv.value();
            const utc = if (parameters != null) data.utc else null;
            if (utc) |*block| {
                try field.encode(time_parameters.Utc, &tables.sf3_page1_head, block, tables.Ctx3{ .prn = prn }, &w);
                try field.encode(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, &data.klobuchar, .{}, &w);
                try field.encode(Parameters, &tables.sf3_page1_tail, parameters.?, .{}, &w);
            } else w.writeAlternating(sf3_data_bits);
        },
        .eop => |ordinal| {
            pages.header(prn, 2, &w);
            try field.encode(time_parameters.Ggto, &tables.ggto, &data.ggto.at(ordinal), .{}, &w);
            try field.encode(time_parameters.Eop, &time_parameters.eop_rows, &data.eop.?, .{}, &w);
            w.skip(30);
        },
        .reduced => |ordinal| {
            try field.encode(almanac_fields.Reference, &tables.sf3_page3_header, &data.almanac_reference, tables.Ctx3{ .prn = prn }, &w);
            const prns = data.almanacPrns();
            const group = prns.group(reduced_packets, ordinal);
            for (group) |number| try field.encode(almanac_fields.Packet, &tables.reduced, &data.alm[number - 1].?, .{}, &w);
            if (group.len < reduced_packets) {
                w.writeBits(8, 0);
                w.writeAlternating(reduced_packets_end - w.pos);
            }
            w.skip(17);
        },
        .midi => |number| {
            try field.encode(almanac_fields.Reference, &tables.sf3_page4_header, &data.almanac_reference, tables.Ctx3{ .prn = prn }, &w);
            try field.encode(almanac_fields.Packet, &tables.midi, &data.alm[number - 1].?, .{}, &w);
            w.skip(85);
        },
        .dc => |d| try pages.encodeDc(prn, d.epoch, &d.packet, &w),
        .text => |p| pages.encodeText(prn, p, &w),
        .configuration, .ism => |payload| pages.withPrn(payload, prn, &out.words, &w),
    }
    w.writeBits(24, crc24q.ofBits(&out.words, sf3_data_bits));
    return out;
}

pub fn isDefault(set: *const Set, page: Page, isf: ?bool) bool {
    return isf == null or (page == .utc and set.data.utc == null);
}

const Optional = union(enum) {
    eop,
    dc: struct { batch: *const dc.Batch, differential: messages.Differential },
    text: []const u8,
    configuration: *const publications.Payload,
    ism: *const publications.Payload,
};

fn configurationOf(set: *const Set, supplied: ?*const publications.Content) ?*const publications.Payload {
    if (supplied) |c| if (c.configuration) |*payload| return payload;
    return set.configuration;
}

pub fn pageAt(set: *const Set, prn: u8, index: i64) Page {
    const ordinal = @divFloor(index, 4);
    switch (@mod(index, 4)) {
        0 => return .utc,
        1 => {
            const t: GpsTime = .{ .ms = index * frame_ms };
            const supplied = set.contentAt(t);
            const differential = if (supplied) |c| c.sources.differential else null;
            const batch: ?dc.Batch = blk: {
                if (differential == null) break :blk null;
                const source = set.dc orelse break :blk null;
                break :blk source.batch(dc.epochOf(t), t);
            };

            var buffer: [@typeInfo(Optional).@"union".field_names.len]Optional = undefined;
            var available: std.ArrayList(Optional) = .initBuffer(&buffer);
            if (set.data.eop != null) available.appendAssumeCapacity(.eop);
            if (differential) |declared| {
                if (batch) |*candidate| {
                    if (candidate.targets(prn).len != 0) {
                        available.appendAssumeCapacity(.{
                            .dc = .{ .batch = candidate, .differential = declared },
                        });
                    }
                }
            }
            if (supplied) |c| {
                if (c.sources.text) |message| available.appendAssumeCapacity(.{ .text = message });
            }
            if (configurationOf(set, supplied)) |payload| available.appendAssumeCapacity(.{ .configuration = payload });
            if (supplied) |c| {
                if (c.ism) |*declared| {
                    if (!t.lessThan(declared.reference)) available.appendAssumeCapacity(.{ .ism = &declared.payload });
                }
            }

            const count: i64 = @intCast(available.items.len);
            if (count == 0) return .utc;
            const occurrence = @divFloor(ordinal, count);
            return switch (available.items[@intCast(@mod(ordinal, count))]) {
                .eop => .{ .eop = occurrence },
                .dc => |d| blk: {
                    const target = d.batch.targets(prn).at(occurrence + prn);
                    break :blk .{ .dc = .{
                        .epoch = .{ .t_od = d.batch.t_od },
                        .packet = .{
                            .corr = d.batch.corrections[target - 1].?,
                            .udra = d.differential.udra,
                            .udra_rate = d.differential.udra_rate,
                        },
                    } };
                },
                .text => |message| .{ .text = text.page(message, pages.text_length, occurrence) },
                .configuration => |payload| .{ .configuration = payload },
                .ism => |payload| .{ .ism = payload },
            };
        },
        else => {
            const available = set.data.almanacPrns();
            if (available.len == 0) return .utc;
            if (@mod(index, 4) == 3) return .{ .midi = available.at(ordinal) };
            return .{ .reduced = ordinal };
        },
    }
}
