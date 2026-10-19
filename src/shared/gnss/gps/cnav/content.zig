const time = @import("../../../core.zig").time;
const field = @import("../../../codec.zig").field;
const frame = @import("../../../codec.zig").frame;
const bitwriter = @import("../../../codec.zig").bitwriter;
const crc24q = @import("../../../codec.zig").crc24q;
const klobuchar_fields = @import("../../klobuchar_fields.zig");
const cnvx = @import("../cnvx.zig");
const almanac_fields = @import("../almanac_fields.zig");
const time_parameters = @import("../time_parameters.zig");
const messages = @import("../messages.zig");
const records = @import("../records.zig");
const text = @import("../text.zig");
const ism = @import("../ism.zig");
const dc = @import("../dc.zig");
const tables = @import("tables.zig");
const schedule = @import("schedule.zig");

const GpsTime = time.GpsTime;
const Parameters = @import("../ephemeris_fields.zig").Parameters;
const Carrier = schedule.Carrier;
const Slot = schedule.Slot;

const content_bits = 276;
pub const message_bits = 300;
pub const Message = frame.Bits(message_bits);
const Error = field.Error;

const reduced31_end = 272;
const dc13_end = 270;
const dc14_end = 246;
const type13_position = 6;

const Corrections = struct {
    t_od: GpsTime,
    packets: [6]dc.Packet = undefined,
    len: usize = 0,

    fn add(self: *Corrections, packet: dc.Packet) void {
        self.packets[self.len] = packet;
        self.len += 1;
    }
};

pub const Set = struct {
    data: cnvx.Data,
    publications: []const messages.Publication = &.{},
    dc: ?dc.Source = null,

    pub const Inputs = struct {
        shared: cnvx.Inputs,
        publications: []const messages.Publication = &.{},
        dc: ?dc.Source = null,
    };

    pub fn build(set: *Set, in: Inputs) void {
        set.* = .{ .data = undefined, .publications = in.publications, .dc = in.dc };
        set.data.build(.cnav, in.shared);
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.data.hasRecord(prn);
    }

    pub fn message(self: *const Set, prn: u8, index: i64, carrier: Carrier) ?Message {
        const sv = if (self.data.sv[prn - 1]) |*sv| sv else return null;
        const t: GpsTime = .{ .ms = index * carrier.frameMs() };
        const content = if (messages.Publication.at(self.publications, t)) |p| &p.content else null;
        const flags = cnvx.cnavFlags(sv, if (content) |c| c.integrity else null, prn) orelse {
            const s = schedule.slot(index, carrier, .{
                .utc = false,
                .eop = false,
                .almanac = false,
                .ggto = 0,
                .ism = false,
                .dc = false,
                .text = false,
            });
            return defaultMessage(prn, s.tow_next) catch unreachable;
        };

        const data = &self.data;
        var available: schedule.Available = .{
            .utc = data.utc != null,
            .eop = data.eop != null,
            .almanac = data.almanacPrns().len != 0,
            .ggto = data.ggto.len,
            .ism = blk: {
                const sources = content orelse break :blk false;
                const declared = sources.ism orelse break :blk false;
                break :blk !t.lessThan(declared.reference);
            },
            .dc = if (content) |c| c.differential != null else false,
            .text = if (content) |c| c.text != null else false,
        };

        var s = schedule.slot(index, carrier, available);
        var corr: ?Corrections = null;
        if (s.kind == .clock_differential or
            s.kind == .ephemeris_differential or
            s.kind == .clock_differential_both)
        {
            corr = self.corrections(prn, s, carrier, t, content.?.differential.?);
            if (corr == null) {
                available.dc = false;
                s = schedule.slot(index, carrier, available);
            }
        }
        return self.messageBits(sv.value().?, prn, s, flags, content, if (corr) |*c| c else null) catch unreachable;
    }

    fn corrections(self: *const Set, prn: u8, s: Slot, carrier: Carrier, t: GpsTime, declared: messages.Differential) ?Corrections {
        const source = self.dc orelse return null;
        const packet = struct {
            fn of(c: dc.Correction, d: messages.Differential) dc.Packet {
                return .{ .corr = c, .udra = d.udra, .udra_rate = d.udra_rate };
            }
        }.of;
        switch (carrier) {
            .l5 => {
                const b = source.batch(dc.epochOf(t), t) orelse return null;
                const targets = b.targets(prn);
                if (targets.len == 0) return null;
                var out: Corrections = .{ .t_od = b.t_od };
                const ordinal = schedule.dc_messages_per_superframe * s.dc_cycle + s.dc_step + prn;
                const target = targets.at(ordinal);
                const correction = b.corrections[target - 1].?;
                out.add(packet(correction, declared));
                return out;
            },
            .l2c => {
                const at = typeThirteenTime(s.dc_cycle);
                const b = source.batch(dc.epochOf(at), at) orelse return null;
                const targets = b.targets(prn);
                if (targets.len == 0) return null;
                const group = targets.group(tables.msg13_packets, s.dc_cycle + prn);
                var out: Corrections = .{ .t_od = b.t_od };
                const now = source.batch(b.t_od, t) orelse return out;
                var members: [2]usize = undefined;
                const picks: []const usize = if (s.dc_step == 0) &[_]usize{ 0, 1, 2, 3, 4, 5 } else blk: {
                    const first = 2 * (@as(usize, s.dc_step) - 1);
                    members = .{ first % group.len, (first + 1) % group.len };
                    break :blk if (members[0] == members[1]) members[0..1] else members[0..2];
                };
                for (picks) |k| {
                    if (k >= group.len) break;
                    if (now.corrections[group[k] - 1]) |c| out.add(packet(c, declared));
                }
                return out;
            },
        }
    }

    fn messageBits(self: *const Set, sv: *const Parameters, prn: u8, s: Slot, flags: records.CnavFlags, content: ?*const messages.Sources, corr: ?*const Corrections) Error!Message {
        const data = &self.data;
        const ctx = tables.Ctx{
            .prn = @intCast(prn),
            .tow = s.tow_next,
            .alert = flags.alert,
            .isf = flags.integrity_status,
            .phasing = flags.l2c_phasing,
        };
        var out: Message = .{};
        var w = out.writer();
        switch (s.kind) {
            .ephemeris_1 => try field.encode(Parameters, &tables.msg10, sv, ctx, &w),
            .ephemeris_2 => try field.encode(Parameters, &tables.msg11, sv, ctx, &w),
            .clock_iono => {
                try field.encode(Parameters, &tables.msg30_head, sv, ctx, &w);
                try field.encode(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, &data.klobuchar, ctx, &w);
                try field.encode(Parameters, &tables.msg30_tail, sv, ctx, &w);
            },
            .clock_utc => {
                try field.encode(Parameters, &tables.clockMessage(.clock_utc), sv, ctx, &w);
                try field.encode(time_parameters.Utc, &tables.msg33_tail, &data.utc.?, ctx, &w);
            },
            .clock_eop => {
                try field.encode(Parameters, &tables.clockMessage(.clock_eop), sv, ctx, &w);
                try field.encode(time_parameters.Eop, &tables.msg32_tail, &data.eop.?, ctx, &w);
            },
            .clock_ggto => {
                try field.encode(Parameters, &tables.clockMessage(.clock_ggto), sv, ctx, &w);
                try field.encode(time_parameters.Ggto, &tables.msg35_tail, &data.ggto.at(s.ggto), ctx, &w);
            },
            .clock_reduced_almanac => {
                try field.encode(Parameters, &tables.clockMessage(.clock_reduced_almanac), sv, ctx, &w);
                try field.encode(almanac_fields.Reference, &almanac_fields.reference, &data.almanac_reference, .{}, &w);
                try reducedPackets(data, data.almanacPrns().group(4, s.almanac), 4, reduced31_end, &w);
                try field.encode(field.NoSource, &tables.msg31_tail, &field.no_source, ctx, &w);
            },
            .reduced_almanac => {
                try field.encode(almanac_fields.Reference, &tables.msg12_head, &data.almanac_reference, ctx, &w);
                try reducedPackets(data, data.almanacPrns().group(tables.msg12_packets, s.almanac), tables.msg12_packets, content_bits, &w);
            },
            .clock_midi_almanac => {
                try field.encode(Parameters, &tables.clockMessage(.clock_midi_almanac), sv, ctx, &w);
                try field.encode(almanac_fields.Reference, &almanac_fields.reference, &data.almanac_reference, .{}, &w);
                const target = data.almanacPrns().at(s.almanac);
                const almanac = &data.alm[target - 1].?;
                try field.encode(almanac_fields.Packet, &almanac_fields.midi(6), almanac, .{}, &w);
            },
            inline .clock_differential, .ephemeris_differential => |kind| {
                const c = corr.?;
                const epoch: dc.Epoch = .{ .t_od = c.t_od };
                try field.encode(dc.Epoch, &tables.dcHead(kind), &epoch, ctx, &w);
                const cdc = kind == .clock_differential;
                const slots: usize = if (cdc) tables.msg13_packets else tables.msg14_packets;
                for (0..slots) |k| {
                    w.writeBits(1, dc.data_type_lnav);
                    if (k == c.len) {
                        w.writeBits(8, dc.no_data_prn);
                        w.writeAlternating((if (cdc) dc13_end else dc14_end) - w.pos);
                        break;
                    }
                    try field.encode(dc.Packet, if (cdc) &dc.cdc else &dc.edc, &c.packets[k], .{}, &w);
                }
                w.skip(content_bits - w.pos);
            },
            .clock_differential_both => {
                const c = corr.?;
                const epoch: dc.Epoch = .{ .t_od = c.t_od };
                try field.encode(Parameters, &tables.msg34_head, sv, ctx, &w);
                try field.encode(dc.Epoch, &dc.epoch, &epoch, .{}, &w);
                w.writeBits(1, dc.data_type_lnav);
                try field.encode(dc.Packet, &dc.cdc, &c.packets[0], .{}, &w);
                try field.encode(dc.Packet, &dc.edc, &c.packets[0], .{}, &w);
            },
            .text => {
                const page = text.page(content.?.text.?, tables.msg15_characters, s.text);
                try field.encode(field.NoSource, &tables.msg15_head, &field.no_source, ctx, &w);
                text.write(&w, &page.characters);
                w.writeBits(4, page.number);
                try field.encode(field.NoSource, &tables.msg15_tail, &field.no_source, ctx, &w);
            },
            .clock_text => {
                const page = text.page(content.?.text.?, tables.msg36_characters, s.text);
                try field.encode(Parameters, &tables.msg36_head, sv, ctx, &w);
                text.write(&w, &page.characters);
                w.writeBits(4, page.number);
                try field.encode(field.NoSource, &tables.msg36_tail, &field.no_source, ctx, &w);
            },
            .ism => {
                try field.encode(field.NoSource, &tables.msg40_head, &field.no_source, ctx, &w);
                const start = w.pos;
                try ism.encode(&content.?.ism.?, &w, tables.msg40_filler);
                w.writeBits(32, ism.crc(&out.words, start, w.pos));
            },
        }
        w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
        return out;
    }
};

fn typeThirteenTime(cycle: i64) GpsTime {
    return .{ .ms = (cycle * schedule.messages_per_superframe + type13_position) * Carrier.l2c.frameMs() };
}

fn reducedPackets(data: *const cnvx.Data, group: []const u6, size: usize, end: usize, w: *bitwriter.BitWriter) Error!void {
    for (group) |p| try field.encode(almanac_fields.Packet, &almanac_fields.reduced(6), &data.alm[p - 1].?, .{}, w);
    if (group.len < size) {
        w.writeBits(6, 0);
        w.writeAlternating(end - w.pos);
    }
}

fn defaultMessage(prn: u8, tow: u17) Error!Message {
    var out: Message = .{};
    var w = out.writer();
    try field.encode(field.NoSource, &tables.msg0_header, &field.no_source, tables.Ctx{ .prn = @intCast(prn), .tow = tow, .alert = true }, &w);
    w.writeAlternating(content_bits - w.pos);
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}
