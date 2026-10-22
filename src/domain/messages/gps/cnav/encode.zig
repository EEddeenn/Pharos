const publications = @import("domain/messages/gps/cnav2/publications");
const almanac_epoch = @import("domain/messages/fields/almanac_reference");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const bit_writer = @import("base/binary/bit_writer");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const almanac_fields = @import("domain/messages/gps/fields/almanac");
const time_parameters = @import("domain/messages/gps/fields/time");
const messages = @import("domain/messages/gps/publication");
const gps_records = @import("domain/navigation/records/gps");
const text = @import("domain/messages/gps/text");
const ism = @import("domain/messages/gps/ism");
const dc = @import("domain/messages/gps/differential");
const fields = @import("domain/messages/gps/cnav/fields");
const schedule = @import("domain/messages/gps/cnav/schedule");
const conv = @import("base/binary/convolution");
const shared_content = @import("domain/messages/gps/cnav_common/content");
const shared_set = @import("domain/messages/gps/cnav_common/set");
const Set = @import("domain/messages/gps/cnav/set").Set;
const crc24q = @import("base/binary/crc").crc24q;
const GpsTime = time.GpsTime;
const Parameters = @import("domain/messages/gps/fields/ephemeris").Parameters;
const Slot = schedule.Slot;
const Error = field.Error;
const content_bits = 276;
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

pub const message_bits = 300;
pub const Message = frame.Bits(message_bits);
pub const Carrier = schedule.Carrier;
pub const frame_ms = schedule.frame_ms;
pub const bits_per_frame = 2 * message_bits;
pub const Frame = frame.Bits(bits_per_frame);

pub fn buildFrame(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    return buildFrameAfter(set, set, prn, index, carrier);
}

pub fn buildFrameAfter(set: *const Set, previous_set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    const m = message(set, prn, index, carrier) orelse return null;
    const previous = message(previous_set, prn, index - 1, carrier) orelse return null;
    return encodeSymbols(&m, tailState(&previous));
}

fn message(self: *const Set, prn: u8, index: i64, carrier: Carrier) ?Message {
    const sv = if (self.navigation.sv[prn - 1]) |sv| sv else return null;
    const t: GpsTime = .{ .ms = index * carrier.frameMs() };
    const content = if (publications.PreparedPublication.at(self.publications, t)) |p| p.content.declaration else null;
    const parameters = sv.value() orelse {
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
    const flags = shared_content.cnavFlags(parameters, if (content) |c| c.integrity else null, prn);

    const data = &self.navigation;
    var available: schedule.Available = .{
        .utc = data.system.utc != null,
        .eop = data.system.eop != null,
        .almanac = data.almanacs.prns.len != 0,
        .ggto = data.system.ggto.len,
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
        corr = corrections(self, prn, s, carrier, t, content.?.differential.?);
        if (corr == null) {
            available.dc = false;
            s = schedule.slot(index, carrier, available);
        }
    }
    return messageBits(self, parameters, prn, s, flags, content, if (corr) |*c| c else null) catch unreachable;
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
            const group = targets.group(fields.msg13_packets, s.dc_cycle + prn);
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

fn messageBits(self: *const Set, sv: *const Parameters, prn: u8, s: Slot, flags: gps_records.CnavFlags, content: ?*const messages.Declaration, corr: ?*const Corrections) Error!Message {
    const data = &self.navigation;
    const ctx = fields.Ctx{
        .prn = @intCast(prn),
        .tow = s.tow_next,
        .alert = flags.alert,
        .isf = flags.integrity_status,
        .phasing = flags.l2c_phasing,
    };
    var out: Message = .{};
    var w = out.writer();
    switch (s.kind) {
        .ephemeris_1 => try field.encode(Parameters, &fields.msg10, sv, ctx, &w),
        .ephemeris_2 => try field.encode(Parameters, &fields.msg11, sv, ctx, &w),
        .clock_iono => {
            try field.encode(Parameters, &fields.msg30_head, sv, ctx, &w);
            field.writeDecoded(klobuchar_fields.Coefficients, &klobuchar_fields.coefficients, data.system.klobuchar, &w);
            try field.encode(Parameters, &fields.msg30_tail, sv, ctx, &w);
        },
        .clock_utc => {
            try field.encode(Parameters, &fields.clockMessage(.clock_utc), sv, ctx, &w);
            field.writeDecoded(time_parameters.Utc, &fields.msg33_tail, data.system.utc.?, &w);
        },
        .clock_eop => {
            try field.encode(Parameters, &fields.clockMessage(.clock_eop), sv, ctx, &w);
            field.writeDecoded(time_parameters.Eop, &fields.msg32_tail, data.system.eop.?, &w);
        },
        .clock_ggto => {
            try field.encode(Parameters, &fields.clockMessage(.clock_ggto), sv, ctx, &w);
            field.writeDecoded(time_parameters.Ggto, &fields.msg35_tail, data.system.ggto.at(s.ggto), &w);
        },
        .clock_reduced_almanac => {
            try field.encode(Parameters, &fields.clockMessage(.clock_reduced_almanac), sv, ctx, &w);
            try field.encode(almanac_epoch.Reference, &almanac_epoch.rows, &data.almanacs.reference, .{}, &w);
            try reducedPackets(data, data.almanacs.prns.group(4, s.almanac), 4, reduced31_end, &w);
            try field.encode(field.NoSource, &fields.msg31_tail, &field.no_source, ctx, &w);
        },
        .reduced_almanac => {
            try field.encode(almanac_epoch.Reference, &fields.msg12_head, &data.almanacs.reference, ctx, &w);
            try reducedPackets(data, data.almanacs.prns.group(fields.msg12_packets, s.almanac), fields.msg12_packets, content_bits, &w);
        },
        .clock_midi_almanac => {
            try field.encode(Parameters, &fields.clockMessage(.clock_midi_almanac), sv, ctx, &w);
            try field.encode(almanac_epoch.Reference, &almanac_epoch.rows, &data.almanacs.reference, .{}, &w);
            const target = data.almanacs.prns.at(s.almanac);
            const almanac = data.almanacs.entries[target - 1].?;
            try field.encode(almanac_fields.Packet, &almanac_fields.midi(6), almanac, .{}, &w);
        },
        inline .clock_differential, .ephemeris_differential => |kind| {
            const c = corr.?;
            const epoch: dc.Epoch = .{ .t_od = c.t_od };
            try field.encode(dc.Epoch, &fields.dcHead(kind), &epoch, ctx, &w);
            const cdc = kind == .clock_differential;
            const slots: usize = if (cdc) fields.msg13_packets else fields.msg14_packets;
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
            try field.encode(Parameters, &fields.msg34_head, sv, ctx, &w);
            try field.encode(dc.Epoch, &dc.epoch, &epoch, .{}, &w);
            w.writeBits(1, dc.data_type_lnav);
            try field.encode(dc.Packet, &dc.cdc, &c.packets[0], .{}, &w);
            try field.encode(dc.Packet, &dc.edc, &c.packets[0], .{}, &w);
        },
        .text => {
            const page = text.page(content.?.text.?, fields.msg15_characters, s.text);
            try field.encode(field.NoSource, &fields.msg15_head, &field.no_source, ctx, &w);
            text.write(&w, &page.characters);
            w.writeBits(4, page.number);
            try field.encode(field.NoSource, &fields.msg15_tail, &field.no_source, ctx, &w);
        },
        .clock_text => {
            const page = text.page(content.?.text.?, fields.msg36_characters, s.text);
            try field.encode(Parameters, &fields.msg36_head, sv, ctx, &w);
            text.write(&w, &page.characters);
            w.writeBits(4, page.number);
            try field.encode(field.NoSource, &fields.msg36_tail, &field.no_source, ctx, &w);
        },
        .ism => {
            try field.encode(field.NoSource, &fields.msg40_head, &field.no_source, ctx, &w);
            const start = w.pos;
            ism.encode(&content.?.ism.?, &w, fields.msg40_filler);
            w.writeBits(32, ism.crc(&out.words, start, w.pos));
        },
    }
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}

fn typeThirteenTime(cycle: i64) GpsTime {
    return .{ .ms = (cycle * schedule.messages_per_superframe + type13_position) * Carrier.l2c.frameMs() };
}

fn reducedPackets(data: *const shared_set.View, group: []const u6, size: usize, end: usize, w: *bit_writer.BitWriter) Error!void {
    for (group) |p| try field.encode(almanac_fields.Packet, &almanac_fields.reduced(6), data.almanacs.entries[p - 1].?, .{}, w);
    if (group.len < size) {
        w.writeBits(6, 0);
        w.writeAlternating(end - w.pos);
    }
}

fn defaultMessage(prn: u8, tow: u17) Error!Message {
    var out: Message = .{};
    var w = out.writer();
    try field.encode(field.NoSource, &fields.msg0_header, &field.no_source, fields.Ctx{ .prn = @intCast(prn), .tow = tow, .alert = true }, &w);
    w.writeAlternating(content_bits - w.pos);
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}

fn tailState(m: *const Message) u6 {
    var state: u6 = 0;
    for (0..6) |i| state |= @as(u6, m.get(message_bits - 1 - i)) << @intCast(i);
    return state;
}

fn encodeSymbols(m: *const Message, state: u6) Frame {
    var encoder = conv.Encoder{ .state = state };
    var out: Frame = .{};
    for (0..message_bits) |i| {
        const s = encoder.push(m.get(i));
        out.set(2 * i, s.g1);
        out.set(2 * i + 1, s.g2);
    }
    return out;
}
