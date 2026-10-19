const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const records = @import("../records.zig");
const reference = @import("../reference.zig");
const projection = @import("projection.zig");
const auxiliary = @import("../auxiliary.zig");
const tables = @import("inav/tables.zig");
const almanac = @import("inav/almanac.zig");
const almanac_fields = @import("almanac_fields.zig");
const time_parameters = @import("time_parameters.zig");
const iono_fields = @import("iono_fields.zig");
const page = @import("inav/page.zig");
const schedule = @import("inav/schedule.zig");
const fec2 = @import("inav/fec2.zig");
const reduced = @import("inav/reduced.zig");
const kepler = @import("../kepler.zig");
const types = @import("../../core.zig").types;
pub const ism = @import("inav/ism.zig");

const Eph = records.KeplerEphemeris;
const Alm = records.KeplerAlmanac;
const GpsTime = time.GpsTime;

pub const frame_ms = schedule.frame_ms;
pub const bits_per_frame = page.symbols_per_page;
const offset_ms = schedule.offset_ms;
pub const Carrier = schedule.Carrier;
const slot = schedule.slot;
pub const Frame = page.Page;
const Word = page.Word;
pub const Error = field.Error;

const Sv = struct { eph: Eph, parity: [fec2.parity_len]u8 };

pub const Set = struct {
    sv: [36]?Sv,
    groups: [12]almanac_fields.Group,
    iono: iono_fields.Coefficients,
    utc: ?time_parameters.Utc,
    publications: []const ism.PreparedPublication = &.{},

    pub const Inputs = struct {
        eph: [36]?*const Content,
        almanacs: []const Alm,
        nequick: ?iono_fields.Coefficients,
        utc: ?auxiliary.UtcParams,
        ggto: ?auxiliary.TimeOffset,
        publications: []const ism.PreparedPublication = &.{},
        t: GpsTime,
    };

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.* = .{
            .sv = @splat(null),
            .groups = undefined,
            .iono = in.nequick orelse .zero,
            .utc = time_parameters.utcBlock(in.utc, in.t),
            .publications = in.publications,
        };
        set.groups = almanac_fields.almanacGroups(in.almanacs, time_parameters.ggtoBlock(in.ggto, in.t), in.t);

        for (in.eph, &set.sv) |entry, *sv| {
            const eph = (entry orelse continue).value() orelse continue;
            sv.* = .{ .eph = eph.*, .parity = try parityOf(eph) };
        }
        try set.validate();
    }

    fn validate(self: *const Set) Error!void {
        for (&self.sv) |*entry| if (entry.*) |*sv| {
            _ = try self.wordBits(sv, 5, 0, .{});
        };
    }

    fn wordBits(self: *const Set, sv: *const Sv, word: u6, group: u4, ctx: tables.Ctx) Error!Word {
        var out: Word = .{};
        var w = out.writer();
        switch (word) {
            0 => try field.encode(field.NoSource, &tables.word0, &field.no_source, ctx, &w),
            1 => try field.encode(Eph, &tables.word1, &sv.eph, ctx, &w),
            2 => try field.encode(Eph, &tables.word2, &sv.eph, ctx, &w),
            3 => try field.encode(Eph, &tables.word3, &sv.eph, ctx, &w),
            4 => try field.encode(Eph, &tables.word4, &sv.eph, ctx, &w),
            5 => {
                try field.encode(iono_fields.Coefficients, &tables.word5_iono, &self.iono, ctx, &w);
                try field.encode(Eph, &tables.word5, &sv.eph, ctx, &w);
            },
            6 => if (self.utc) |*utc| try field.encode(time_parameters.Utc, &tables.word6, utc, ctx, &w) else return dummy_word,
            7 => try field.encode(almanac_fields.Group, &almanac.word7, &self.groups[group], ctx, &w),
            8 => try field.encode(almanac_fields.Group, &almanac.word8, &self.groups[group], ctx, &w),
            9 => try field.encode(almanac_fields.Group, &almanac.word9, &self.groups[group], ctx, &w),
            10 => {
                try field.encode(almanac_fields.Group, &almanac.word10, &self.groups[group], ctx, &w);
                try field.encode(time_parameters.Ggto, &almanac.word10_ggto, &self.groups[group].ggto, ctx, &w);
            },
            16 => {
                const week = time.resolveWeek(ctx.wn, time.week_modulus_12, sv.eph.toe.week() - time.gal_week_offset);
                const tow: i64 = ctx.tow;
                return reduced.build(&sv.eph, GpsTime.fromScaleWeekMs(.gal, week, tow * 1000, 0)) orelse dummy_word;
            },
            17, 18, 19, 20 => {
                const parity = sv.parity[@as(usize, word - 17) * 15 ..][0..15];
                w.writeBits(6, word);
                w.writeBits(8, parity[0]);
                w.writeBits(2, @as(u2, @truncate(sv.eph.extra.inav.iod_nav)));
                for (parity[1..]) |octet| w.writeBits(8, octet);
            },
            else => return dummy_word,
        }
        return out;
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.sv[prn - 1] != null;
    }
};

pub const Content = @import("../content.zig").Carriage(Eph);

/// I/NAV's content for a leg: its own record, with the leg's BGDs, or the first of its fields it does not fit. I/NAV
/// carries no other family's record.
pub fn prepare(e: reference.Kepler) Content {
    if (e.record.source() != .inav) return .{ .unfit = .record };
    const out = projection.forSource(e, .inav);
    if (misfit(&out)) |name| return .{ .unfit = .{ .field = name } };
    return .{ .carried = out };
}

pub fn valid(e: *const Eph, sat: types.SatId) bool {
    return e.sat == sat and e.extra == .inav and misfit(e) == null and kepler.misfit(e) == null;
}

fn misfit(e: *const Eph) ?[:0]const u8 {
    inline for (.{ &tables.word1, &tables.word2, &tables.word3, &tables.word4, &tables.word5 }) |rows| {
        if (field.misfit(Eph, rows, e)) |name| return name;
    }
    return null;
}

fn parityOf(eph: *const Eph) Error![fec2.parity_len]u8 {
    var info: [fec2.info_len]u8 = undefined;
    inline for (.{ &tables.word1, &tables.word2, &tables.word3, &tables.word4 }, 0..) |layout, k| {
        var word: Word = .{};
        var w = word.writer();
        try field.encode(Eph, layout, eph, tables.Ctx{}, &w);
        const bytes = word.toBytes();
        if (k == 0) {
            info[0] = (bytes[0] & 0xFC) | (bytes[1] & 0x03);
            info[1] = (bytes[0] << 6) | (bytes[1] >> 2);
        }
        info[2 + k * 14 ..][0..14].* = bytes[2..16].*;
    }
    return fec2.parity(&info);
}

const dummy_word_type = 63;

const dummy_word: Word = blk: {
    var out: Word = .{};
    var w = out.writer();
    w.writeBits(6, dummy_word_type);
    break :blk out;
};

fn buildWord(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Word {
    const sv = if (set.sv[prn - 1]) |*entry| entry else return null;
    const s = slot(index, carrier);
    var word = s.word;
    if (word == 22) {
        const transmitted: GpsTime = .{ .ms = index * frame_ms - offset_ms };
        if (ism.PreparedPublication.at(set.publications, transmitted)) |publication| {
            if (publication.content.available(transmitted)) return publication.content.word;
        }
        word = 63;
    }
    return set.wordBits(sv, word, s.group, .{ .wn = s.wn, .tow = s.tow }) catch unreachable;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    const word = buildWord(set, prn, index, carrier) orelse return null;
    return page.encode(&word, slot(index, carrier).ssp);
}
