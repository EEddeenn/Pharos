const time = @import("../../core.zig").time;
const iono = @import("../../core.zig").iono;
const SatId = @import("../../core.zig").types.SatId;
const records = @import("../records.zig");
const nav_reference = @import("../reference.zig");
const auxiliary = @import("../auxiliary.zig");
const bitwriter = @import("../../codec.zig").bitwriter;
const field = @import("../../codec.zig").field;
const frame = @import("../../codec.zig").frame;
const tables = @import("lnav/tables.zig");
pub const misfit = tables.misfit;
pub const almanac_page = tables.almanac_page;
const messages = @import("messages.zig");
const text = @import("text.zig");
const word = @import("lnav/word.zig");
const almanac_reference = @import("../almanac_reference.zig");
const kepler = @import("../kepler.zig");

const Eph = records.KeplerEphemeris;
const Alm = records.KeplerAlmanac;

pub const frame_ms = 6000;
pub const bits_per_frame = 300;
const frames_per_week = 100_800;
pub const toe_step_ms = 16_000;
const tot_step_s = 4096;
const health_unusable: u6 = 0x3F;
const as_flag: u4 = 0b1000;
const data_bits_per_subframe = 240;
const subframes_per_superframe = 125;
const fill_first_bit = 60;
const fill_end_bit = 298;
pub const Frame = frame.Bits(bits_per_frame);
const Error = field.Error;

const Slot = struct {
    subframe: u3,
    page: u5,
    tow_next: u17,
    wn: u10,
};

fn slot(index: i64) Slot {
    const in_week = @mod(index, frames_per_week);
    return .{
        .subframe = @intCast(@mod(in_week, 5) + 1),
        .page = @intCast(@mod(@divFloor(in_week, 5), 25)),
        .tow_next = @intCast(@mod(in_week + 1, frames_per_week)),
        .wn = @intCast(@mod(time.weekOfIndex(index, frames_per_week, .gps), time.week_modulus_10)),
    };
}

pub const Set = struct {
    eph: [32]?Eph,
    alm: [32]?Alm,
    page18: ?tables.Page18,
    health: tables.Health,
    publications: []const messages.Publication = &.{},

    pub const Inputs = struct {
        eph: [32]?*const Content,
        almanacs: []const Alm,
        klobuchar: iono.klobuchar.Model,
        utc: ?auxiliary.UtcParams,
        publications: []const messages.Publication = &.{},
        configuration: [63]u3 = @splat(0),
    };

    pub fn build(set: *Set, in: Inputs) void {
        set.* = .{ .eph = @splat(null), .alm = @splat(null), .page18 = null, .health = undefined, .publications = in.publications };
        for (in.eph, &set.eph) |entry, *eph| if (entry) |c| if (c.value()) |e| {
            eph.* = e.*;
        };
        var toa: ?time.GpsTime = null;
        for (in.almanacs) |a| {
            if (!field.fits(Alm, &tables.almanac_page, &a) or a.toa.sub_ms != 0 or a.toa.msOfWeek() % almanac_reference.toa_step_ms != 0) continue;
            if (!a.toa.eql(toa orelse a.toa)) continue;
            toa = a.toa;
            set.alm[a.sat.prn() - 1] = a;
        }
        if (in.utc) |utc| {
            if (utc.leap) |leap| {
                if (utc.a2 == 0 and utc.tot_s % tot_step_s == 0) {
                    const page = tables.Page18.init(.of(in.klobuchar), utc, leap);
                    if (field.fits(tables.Page18, &tables.page18, &page)) set.page18 = page;
                }
            }
        }
        set.health = healthOf(&set.alm, &in.configuration);
    }

    fn healthOf(alm: *const [32]?Alm, configuration: *const [63]u3) tables.Health {
        var h: tables.Health = .{ .toa = 0, .wna = 0, .sv = @splat(health_unusable), .as_config = undefined };
        for (&h.as_config, configuration[0..32]) |*term, code| term.* = as_flag | @as(u4, code);
        var reference: ?Alm = null;
        for (alm, 0..) |entry, i| {
            const a = entry orelse continue;
            if (reference == null) reference = a;
            const summary: u6 = if (a.health >> 5 != 0) 0x20 else 0;
            h.sv[i] = summary | @as(u6, @intCast(a.health & 0x1F));
        }
        if (reference) |a| {
            h.toa = @intCast(a.toa.msOfWeek() / almanac_reference.toa_step_ms);
            h.wna = @intCast(@mod(a.toa.week(), time.week_modulus_8));
        }
        return h;
    }

    fn contentAt(self: *const Set, index: i64) ?*const messages.Sources {
        const publication = messages.Publication.at(self.publications, .{ .ms = index * frame_ms }) orelse return null;
        return &publication.content;
    }

    fn encodeContent(self: *const Set, eph: *const Eph, prn: u8, index: i64, content: ?*const messages.Sources, w: *bitwriter.BitWriter) Error!void {
        const s = slot(index);
        var ctx = tables.Ctx{ .wn = s.wn, .tow_next = s.tow_next, .subframe = s.subframe };
        if (content) |c| {
            if (c.integrity) |d| {
                ctx.isf = d.isf;
                ctx.alert = @intFromBool(d.alerts(prn));
            }
        }
        try field.encode(field.NoSource, &tables.tlm, &field.no_source, ctx, w);
        try field.encode(field.NoSource, &tables.how, &field.no_source, ctx, w);
        switch (s.subframe) {
            1 => try field.encode(Eph, &tables.sf1, eph, ctx, w),
            2 => try field.encode(Eph, &tables.sf2, eph, ctx, w),
            3 => try field.encode(Eph, &tables.sf3, eph, ctx, w),
            4 => try self.encodeSubframe4(index, content, ctx, w),
            else => try self.encodeSubframe5(s.page, ctx, w),
        }
    }

    fn encodeSubframe4(self: *const Set, index: i64, content: ?*const messages.Sources, ctx: tables.Ctx, w: *bitwriter.BitWriter) Error!void {
        const page = slot(index).page;
        const id = tables.sf4_page_ids[page];
        switch (page) {
            1, 2, 3, 4, 6, 7, 8, 9 => try self.almanacPage(id, ctx, w),
            12 => try field.encode(field.NoSource, &tables.page13, &field.no_source, ctx, w),
            16 => if (textOf(content)) |t| {
                const p: tables.Page17 = .{ .characters = text.page(t, 22, @divFloor(index, subframes_per_superframe)).characters };
                try field.encode(tables.Page17, &tables.page17, &p, ctx, w);
            },
            17 => if (self.page18) |*p| try field.encode(tables.Page18, &tables.page18, p, ctx, w),
            24 => {
                var health = self.health;
                if (content) |c| {
                    if (c.configuration) |codes| {
                        for (&health.as_config, codes[0..32]) |*term, code| term.* = as_flag | @as(u4, code);
                    }
                }
                try field.encode(tables.Health, &tables.sf4_page25, &health, ctx, w);
            },
            else => try filler(id, ctx, w),
        }
    }

    fn textOf(content: ?*const messages.Sources) ?[]const u8 {
        return (content orelse return null).text;
    }

    fn encodeSubframe5(self: *const Set, page: u5, ctx: tables.Ctx, w: *bitwriter.BitWriter) Error!void {
        if (page == 24) return field.encode(tables.Health, &tables.sf5_page25, &self.health, ctx, w);
        try self.almanacPage(@as(u6, page) + 1, ctx, w);
    }

    fn almanacPage(self: *const Set, sv: u6, ctx: tables.Ctx, w: *bitwriter.BitWriter) Error!void {
        if (self.alm[sv - 1]) |*a| return field.encode(Alm, &tables.almanac_page, a, ctx, w);
        try filler(0, ctx, w);
    }

    fn filler(id: u6, ctx: tables.Ctx, w: *bitwriter.BitWriter) Error!void {
        var page_ctx = ctx;
        page_ctx.page_sv_id = id;
        try field.encode(field.NoSource, &tables.filler_page, &field.no_source, page_ctx, w);
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.eph[prn - 1] != null;
    }
};

pub const Content = @import("../content.zig").Carriage(Eph);

/// LNAV's content for a leg: its own record as LNAV describes it, with the leg's T_GD. LNAV carries no other family's
/// record.
pub fn prepare(e: nav_reference.Kepler) Content {
    if (e.record.source() != .lnav) return .{ .unfit = .record };
    var out = e.record.*;
    out.extra = e.attribute(.lnav) orelse unreachable;
    out.group_delay = .{};
    if (e.delay(.l1ca, .data)) |tgd| out.group_delay.put(.tgd_l1ca, tgd);
    if (!field.fits(Eph, &.{field.rowOf(Eph, &tables.sf1, "tgd")}, &out)) return .{ .unfit = .{ .field = "tgd" } };
    return .{ .carried = out };
}

pub fn valid(e: *const Eph, sat: SatId) bool {
    return e.sat == sat and e.extra == .lnav and misfit(e) == null and kepler.misfit(e) == null;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const eph = if (set.eph[prn - 1]) |*e| e else return null;
    var bits: frame.Bits(data_bits_per_subframe) = .{};
    var w = bits.writer();
    const s = slot(index);
    const content = set.contentAt(index);
    set.encodeContent(eph, prn, index, content, &w) catch unreachable;
    var source: [10]u24 = @splat(0);
    for (0..data_bits_per_subframe) |i| source[i / 24] = (source[i / 24] << 1) | bits.get(i);
    var out = Frame.fromWords(30, 10, word.encodeSubframe(source));
    const missing = switch (s.page) {
        16 => Set.textOf(content) == null,
        17 => set.page18 == null,
        else => false,
    };
    if (s.subframe == 4 and missing) {
        var i: usize = fill_first_bit;
        while (i < fill_end_bit) : (i += 2) {
            out.set(i, 1);
            out.set(i + 1, 0);
        }
        out.set(fill_end_bit, 0);
        out.set(fill_end_bit + 1, 0);
    }
    return out;
}
