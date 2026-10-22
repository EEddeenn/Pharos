const nequick = @import("domain/propagation/ionosphere/nequick");
const fnav_set = @import("domain/messages/galileo/fnav/set");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const fields = @import("domain/messages/galileo/fnav/fields");
const time_parameters = @import("domain/messages/galileo/fields/time");
const almanac_fields = @import("domain/messages/galileo/fields/almanac");
const page = @import("domain/messages/galileo/fnav/page");
const Error = field.Error;
const Set = fnav_set.Set;
const Parameters = @import("domain/messages/galileo/fnav/content").Parameters;
const PageContent = page.Content;
const subframes_per_cycle = 24;
const almanac_groups = subframes_per_cycle / 2;

pub const frame_ms = 10_000;
pub const bits_per_frame = page.symbols_per_page;
pub const Frame = page.Page;
const PageType = enum { clock, ephemeris_1, ephemeris_2, ephemeris_3, almanac_1, almanac_2 };
const record_pages = [_]PageType{ .clock, .ephemeris_1, .ephemeris_2, .ephemeris_3 };
const Slot = struct {
    page: PageType,
    group: u4,
    tow: u20,
    wn: u12,
};

const dummy_page_type = 63;
const dummy_page: PageContent = blk: {
    var content: PageContent = .{};
    var w = content.writer();
    w.writeBits(6, dummy_page_type);
    break :blk content;
};

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const content = buildContent(set, prn, index) orelse return null;
    return page.encode(&content);
}

fn pageBits(self: *const Set, sv: *const Parameters, kind: PageType, group: u4, ctx: fields.Ctx) Error!PageContent {
    var out: PageContent = .{};
    var w = out.writer();
    switch (kind) {
        .clock => if (sv.clock_fits) {
            try field.encode(Parameters, &fields.page1, sv, ctx, &w);
            field.writeDecoded(nequick.Coefficients, &fields.page1_iono, self.system.iono, &w);
            try field.encode(Parameters, &fields.page1_tail, sv, ctx, &w);
        } else return dummy_page,
        .ephemeris_1 => try field.encode(Parameters, &fields.page2, sv, ctx, &w),
        .ephemeris_2 => try field.encode(Parameters, &fields.page3, sv, ctx, &w),
        .ephemeris_3 => if (self.system.utc) |*utc| {
            try field.encode(Parameters, &fields.page4, sv, ctx, &w);
            field.writeDecoded(time_parameters.Utc, &fields.page4_utc, utc.*, &w);
            field.writeDecoded(time_parameters.Ggto, fields.page4_tail[0..4], self.system.ggto, &w);
            w.writeBits(20, ctx.tow);
            w.skip(5);
        } else return dummy_page,
        .almanac_1 => try field.encode(almanac_fields.Group, &fields.page5, &self.almanacs.group(group), ctx, &w),
        .almanac_2 => try field.encode(almanac_fields.Group, &fields.page6, &self.almanacs.group(group), ctx, &w),
    }
    return out;
}

fn slot(index: i64) Slot {
    const start_ms = index * frame_ms;
    const tow = @mod(@divFloor(start_ms, 1000), time.s_per_week);
    const wn = @mod(time.weekOfIndex(start_ms, time.ms_per_week, .gal), time.week_modulus_12);
    const subframe = @divFloor(@mod(tow, 50 * subframes_per_cycle), 50);
    const position = @divFloor(@mod(tow, 50), 10);
    return .{
        .page = if (position < 4) record_pages[@intCast(position)] else if (@mod(subframe, 2) == 0) .almanac_1 else .almanac_2,
        .group = @intCast(@divFloor(subframe, 2)),
        .tow = @intCast(tow),
        .wn = @intCast(wn),
    };
}

fn almanacGroup(group: u4, prn: u8) u4 {
    return @intCast((@as(u32, group) + prn - 1) % almanac_groups);
}

fn buildContent(set: *const Set, prn: u8, index: i64) ?PageContent {
    const sv = if (set.sv[prn - 1]) |entry| entry else return null;
    const s = slot(index);
    return pageBits(set, sv, s.page, almanacGroup(s.group, prn), .{ .wn = s.wn, .tow = s.tow }) catch unreachable;
}
