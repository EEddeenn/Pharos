const std = @import("std");
const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const dc = @import("domain/messages/gps/differential");
const messages = @import("domain/messages/gps/publication");
const text = @import("domain/messages/gps/text");
const fields = @import("domain/messages/gps/cnav2/fields");
const pages = @import("domain/messages/gps/cnav2/pages");
const publications = @import("domain/messages/gps/cnav2/publications");
const time_parameters = @import("domain/messages/gps/fields/time");
const almanac_fields = @import("domain/messages/gps/fields/almanac");
const bch = @import("base/binary/bch");
const ldpc = @import("base/binary/ldpc");
const interleave = @import("base/binary/interleave");
const blobs = @import("domain/messages/gps/data/manifest");
const shared_content = @import("domain/messages/gps/cnav_common/content");
const Set = @import("domain/messages/gps/cnav2/set").Set;
const crc24q = @import("base/binary/crc").crc24q;
const Parameters = @import("domain/messages/gps/fields/ephemeris").Parameters;
const GpsTime = time.GpsTime;
const Error = field.Error;
const Sf2 = frame.Bits(600);
const Sf3 = frame.Bits(274);
const sf2_data_bits = 576;
const sf3_data_bits = 250;
const reduced_packets = 6;
const reduced_packets_end = 233;
const frames_per_week = 33_600;
const frames_per_itow = 400;
const toi_default = 511;
const sf2_bits = 600;
const sf3_bits = 274;
const sf2_codeword_bits = 1200;
const sf3_codeword_bits = 548;
const encoded_bits = 1748;
const subframe2_ldpc = ldpc.Gf2Systematic(sf2_bits, 19).init(blobs.l1c_gen2.bytes);
const subframe3_ldpc = ldpc.Gf2Systematic(sf3_bits, 9).init(blobs.l1c_gen3.bytes);
const interleaver = interleave.block(46, 38);

pub const frame_ms = 18_000;
const Sf2Input = struct { parameters: *const Parameters, isf: bool };
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

const Optional = union(enum) {
    eop,
    dc: struct { batch: *const dc.Batch, differential: messages.Differential },
    text: []const u8,
    configuration: *const publications.Payload,
    ism: *const publications.Payload,
};

pub const bits_per_frame = 1800;
pub const Frame = frame.Bits(bits_per_frame);

const Slot = struct { itow: u8, toi: u9 };

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const sv = if (set.navigation.sv[prn - 1]) |sv| sv else return null;
    const f = slot(index);
    const input: ?Sf2Input = if (sv.value()) |parameters| .{
        .parameters = parameters,
        .isf = isfAt(set, parameters, .{ .ms = index * frame_ms }),
    } else null;
    const sf2 = subframe2Bits(input, f.itow) catch unreachable;
    const page = pageAt(set, prn, index);
    const sf3 = subframe3Bits(set, prn, page) catch unreachable;

    var symbols: [encoded_bits]u1 = undefined;
    for (0..sf2_bits) |i| symbols[i] = sf2.get(i);
    var parity2: [sf2_codeword_bits - sf2_bits]u1 = undefined;
    subframe2_ldpc.parity(&sf2.words, &parity2);
    @memcpy(symbols[sf2_bits..sf2_codeword_bits], &parity2);

    for (0..sf3_bits) |i| symbols[sf2_codeword_bits + i] = sf3.get(i);
    var parity3: [sf3_codeword_bits - sf3_bits]u1 = undefined;
    subframe3_ldpc.parity(&sf3.words, &parity3);
    @memcpy(symbols[sf2_codeword_bits + sf3_bits .. encoded_bits], &parity3);

    var interleaved: [encoded_bits]u1 = undefined;
    interleaver.apply(u1, &symbols, &interleaved);

    var out: Frame = .{};
    const s1 = subframe1(if (isDefault(set, page, input)) toi_default else f.toi);
    for (0..52) |i| out.set(i, @truncate(s1 >> @intCast(51 - i)));
    for (interleaved, 0..) |b, i| out.set(52 + i, b);
    return out;
}

fn contentAt(self: *const Set, t: GpsTime) ?*const publications.Content {
    const publication = publications.PreparedPublication.at(self.publications, t) orelse return null;
    return &publication.content;
}

fn isfAt(self: *const Set, parameters: *const Parameters, t: GpsTime) bool {
    const content = contentAt(self, t);
    return shared_content.cnav2Isf(parameters, if (content) |c| c.declaration.integrity else null);
}

fn subframe2Bits(input: ?Sf2Input, itow: u8) Error!Sf2 {
    var out: Sf2 = .{};
    var w = out.writer();
    if (input) |sv| {
        try field.encode(Parameters, &fields.sf2, sv.parameters, fields.Ctx2{ .itow = itow, .isf = sv.isf }, &w);
    } else {
        w.writeAlternating(sf2_data_bits);
    }
    w.writeBits(24, crc24q.ofBits(&out.words, sf2_data_bits));
    return out;
}

fn subframe3Bits(set: *const Set, prn: u8, page: Page) Error!Sf3 {
    const data = &set.navigation;
    var out: Sf3 = .{};
    var w = out.writer();
    switch (page) {
        .utc => {
            const sv = data.sv[prn - 1].?;
            const parameters = sv.value();
            const utc = if (parameters != null) data.system.utc else null;
            if (utc) |*block| {
                pages.header(prn, 1, &w);
                field.writeDecoded(time_parameters.Utc, &time_parameters.utc_rows, block.*, &w);
                field.writeDecoded(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, data.system.klobuchar, &w);
                try field.encode(Parameters, &fields.sf3_page1_tail, parameters.?, .{}, &w);
            } else w.writeAlternating(sf3_data_bits);
        },
        .eop => |ordinal| {
            pages.header(prn, 2, &w);
            field.writeDecoded(time_parameters.Ggto, &fields.ggto, data.system.ggto.at(ordinal), &w);
            field.writeDecoded(time_parameters.Eop, &time_parameters.eop_rows, data.system.eop.?, &w);
            w.skip(30);
        },
        .reduced => |ordinal| {
            try field.encode(almanac_epoch.Reference, &fields.sf3_page3_header, &data.almanacs.reference, fields.Ctx3{ .prn = prn }, &w);
            const prns = data.almanacs.prns;
            const group = prns.group(reduced_packets, ordinal);
            for (group) |number| try field.encode(almanac_fields.Packet, &fields.reduced, data.almanacs.entries[number - 1].?, .{}, &w);
            if (group.len < reduced_packets) {
                w.writeBits(8, 0);
                w.writeAlternating(reduced_packets_end - w.pos);
            }
            w.skip(17);
        },
        .midi => |number| {
            try field.encode(almanac_epoch.Reference, &fields.sf3_page4_header, &data.almanacs.reference, fields.Ctx3{ .prn = prn }, &w);
            try field.encode(almanac_fields.Packet, &fields.midi, data.almanacs.entries[number - 1].?, .{}, &w);
            w.skip(85);
        },
        .dc => |d| try pages.encodeDc(prn, d.epoch, &d.packet, &w),
        .text => |p| pages.encodeText(prn, p, &w),
        .configuration, .ism => |payload| pages.withPrn(payload, prn, &out.words, &w),
    }
    w.writeBits(24, crc24q.ofBits(&out.words, sf3_data_bits));
    return out;
}

fn isDefault(set: *const Set, page: Page, input: ?Sf2Input) bool {
    return input == null or (page == .utc and set.navigation.system.utc == null);
}

fn configurationOf(set: *const Set, supplied: ?*const publications.Content) *const publications.Payload {
    if (supplied) |c| if (c.configuration) |*payload| return payload;
    return set.configuration;
}

fn pageAt(set: *const Set, prn: u8, index: i64) Page {
    const ordinal = @divFloor(index, 4);
    switch (@mod(index, 4)) {
        0 => return .utc,
        1 => {
            const t: GpsTime = .{ .ms = index * frame_ms };
            const supplied = contentAt(set, t);
            const differential = if (supplied) |c| c.declaration.differential else null;
            const batch: ?dc.Batch = blk: {
                if (differential == null) break :blk null;
                const source = set.dc orelse break :blk null;
                break :blk source.batch(dc.epochOf(t), t);
            };

            var buffer: [@typeInfo(Optional).@"union".field_names.len]Optional = undefined;
            var available: std.ArrayList(Optional) = .initBuffer(&buffer);
            if (set.navigation.system.eop != null) available.appendAssumeCapacity(.eop);
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
                if (c.declaration.text) |message| available.appendAssumeCapacity(.{ .text = message });
            }
            available.appendAssumeCapacity(.{ .configuration = configurationOf(set, supplied) });
            if (supplied) |c| {
                if (c.ism) |*declared| {
                    if (!t.lessThan(declared.reference)) available.appendAssumeCapacity(.{ .ism = &declared.payload });
                }
            }

            const count: i64 = @intCast(available.items.len);
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
            const available = set.navigation.almanacs.prns;
            if (available.len == 0) return .utc;
            if (@mod(index, 4) == 3) return .{ .midi = available.at(ordinal) };
            return .{ .reduced = ordinal };
        },
    }
}

fn subframe1(toi: u9) u52 {
    const msb: u1 = @truncate(toi >> 8);
    const code: u51 = bch.bch51.codeword(@truncate(toi));
    const mixed: u51 = if (msb == 1) ~code else code;
    return (@as(u52, msb) << 51) | mixed;
}

fn slot(index: i64) Slot {
    const page = @mod(index, frames_per_week);
    return .{
        .itow = @intCast(@divFloor(page, frames_per_itow)),
        .toi = @intCast(@mod(page + 1, frames_per_itow)),
    };
}
