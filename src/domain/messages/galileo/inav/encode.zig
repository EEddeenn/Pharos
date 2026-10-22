const content = @import("domain/messages/galileo/inav/content");
const nequick = @import("domain/propagation/ionosphere/nequick");
const inav_set = @import("domain/messages/galileo/inav/set");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const fields = @import("domain/messages/galileo/inav/fields");
const almanac = @import("domain/messages/galileo/inav/almanac");
const almanac_fields = @import("domain/messages/galileo/fields/almanac");
const time_parameters = @import("domain/messages/galileo/fields/time");
const page = @import("domain/messages/galileo/inav/page");
const schedule = @import("domain/messages/galileo/inav/schedule");
const reduced = @import("domain/messages/galileo/inav/reduced");
const ism = @import("domain/messages/galileo/inav/ism");
const Error = field.Error;
const Set = inav_set.Set;
const Parameters = content.Parameters;
const Sv = content.Prepared;
const GpsTime = time.GpsTime;
const offset_ms = schedule.offset_ms;
const slot = schedule.slot;
const Word = page.Word;

pub const frame_ms = schedule.frame_ms;
pub const bits_per_frame = page.symbols_per_page;
pub const Carrier = schedule.Carrier;
pub const Frame = page.Page;
const dummy_word_type = 63;
const dummy_word: Word = blk: {
    var out: Word = .{};
    var w = out.writer();
    w.writeBits(6, dummy_word_type);
    break :blk out;
};

pub fn buildFrame(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    const word = buildWord(set, prn, index, carrier) orelse return null;
    return page.encode(&word, slot(index, carrier).ssp);
}

fn wordBits(self: *const Set, sv: *const Sv, word: u6, group: u4, ctx: fields.Ctx) Error!Word {
    var out: Word = .{};
    var w = out.writer();
    switch (word) {
        0 => try field.encode(field.NoSource, &fields.word0, &field.no_source, ctx, &w),
        1 => try field.encode(Parameters, &fields.word1, &sv.parameters, ctx, &w),
        2 => try field.encode(Parameters, &fields.word2, &sv.parameters, ctx, &w),
        3 => try field.encode(Parameters, &fields.word3, &sv.parameters, ctx, &w),
        4 => try field.encode(Parameters, &fields.word4, &sv.parameters, ctx, &w),
        5 => {
            field.writeDecoded(nequick.Coefficients, &fields.word5_iono, self.system.iono, &w);
            try field.encode(Parameters, &fields.word5, &sv.parameters, ctx, &w);
        },
        6 => if (self.system.utc) |utc| {
            field.writeDecoded(time_parameters.Utc, fields.word6[0 .. fields.word6.len - 2], utc, &w);
            w.writeBits(20, ctx.tow);
            w.skip(3);
        } else return dummy_word,
        7 => try field.encode(almanac_fields.Group, &almanac.word7, &self.almanacs.group(group), ctx, &w),
        8 => try field.encode(almanac_fields.Group, &almanac.word8, &self.almanacs.group(group), ctx, &w),
        9 => try field.encode(almanac_fields.Group, &almanac.word9, &self.almanacs.group(group), ctx, &w),
        10 => {
            try field.encode(almanac_fields.Group, &almanac.word10, &self.almanacs.group(group), ctx, &w);
            field.writeDecoded(time_parameters.Ggto, &almanac.word10_ggto, self.system.ggto, &w);
        },
        16 => {
            const week = time.resolveWeek(ctx.wn, time.week_modulus_12, sv.parameters.eph.toe.week() - time.gal_week_offset);
            const tow: i64 = ctx.tow;
            return reduced.build(&sv.parameters, GpsTime.fromScaleWeekMs(.gal, week, tow * 1000, 0)) orelse dummy_word;
        },
        17, 18, 19, 20 => {
            const parity = sv.parity[@as(usize, word - 17) * 15 ..][0..15];
            w.writeBits(6, word);
            w.writeBits(8, parity[0]);
            w.writeBits(2, @as(u2, @truncate(sv.parameters.iod_nav)));
            for (parity[1..]) |octet| w.writeBits(8, octet);
        },
        else => return dummy_word,
    }
    return out;
}

fn buildWord(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Word {
    const sv = if (set.sv[prn - 1]) |entry| entry else return null;
    const s = slot(index, carrier);
    var word = s.word;
    if (word == 22) {
        const transmitted: GpsTime = .{ .ms = index * frame_ms - offset_ms };
        if (ism.PreparedPublication.at(set.publications, transmitted)) |publication| {
            if (publication.content.available(transmitted)) return publication.content.word;
        }
        word = 63;
    }
    return wordBits(set, sv, word, s.group, .{ .wn = s.wn, .tow = s.tow }) catch unreachable;
}
