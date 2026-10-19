const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const SatId = @import("../../core.zig").types.SatId;
const records = @import("../records.zig");
const reference = @import("../reference.zig");
const projection = @import("projection.zig");
const auxiliary = @import("../auxiliary.zig");
const tables = @import("fnav/tables.zig");
const time_parameters = @import("time_parameters.zig");
const almanac_fields = @import("almanac_fields.zig");
const iono_fields = @import("iono_fields.zig");
const page = @import("fnav/page.zig");

const Eph = records.KeplerEphemeris;
const Alm = records.KeplerAlmanac;
const GpsTime = time.GpsTime;

pub const frame_ms = 10_000;
pub const bits_per_frame = page.symbols_per_page;
const subframes_per_cycle = 24;
const almanac_groups = subframes_per_cycle / 2;
pub const Frame = page.Page;
const PageContent = page.Content;
pub const Error = field.Error;

const PageType = enum { clock, ephemeris_1, ephemeris_2, ephemeris_3, almanac_1, almanac_2 };
const record_pages = [_]PageType{ .clock, .ephemeris_1, .ephemeris_2, .ephemeris_3 };

const Slot = struct {
    page: PageType,
    group: u4,
    tow: u20,
    wn: u12,
};

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

pub const Sv = struct { eph: Eph, clock_fits: bool };

pub const Content = @import("../content.zig").Carriage(Sv);

pub const Set = struct {
    sv: [36]?Sv,
    groups: [12]almanac_fields.Group,
    iono: iono_fields.Coefficients,
    utc: ?time_parameters.Utc,
    ggto: time_parameters.Ggto,

    pub const Inputs = struct {
        eph: [36]?*const Content,
        almanacs: []const Alm,
        nequick: ?iono_fields.Coefficients,
        utc: ?auxiliary.UtcParams,
        ggto: ?auxiliary.TimeOffset,
        t: GpsTime,
    };

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.* = .{
            .sv = @splat(null),
            .groups = undefined,
            .iono = in.nequick orelse .zero,
            .utc = time_parameters.utcBlock(in.utc, in.t),
            .ggto = time_parameters.ggtoBlock(in.ggto, in.t),
        };

        for (in.eph, &set.sv) |entry, *sv| {
            sv.* = ((entry orelse continue).value() orelse continue).*;
        }
        set.groups = almanac_fields.almanacGroups(in.almanacs, set.ggto, in.t);
        try set.validate();
    }

    fn validate(self: *const Set) Error!void {
        for (&self.sv) |*entry| if (entry.*) |*sv| {
            for (record_pages) |kind| _ = try self.pageBits(sv, kind, 0, .{});
        };
    }

    fn pageBits(self: *const Set, sv: *const Sv, kind: PageType, group: u4, ctx: tables.Ctx) Error!PageContent {
        var out: PageContent = .{};
        var w = out.writer();
        switch (kind) {
            .clock => if (sv.clock_fits) {
                try field.encode(Eph, &tables.page1, &sv.eph, ctx, &w);
                try field.encode(iono_fields.Coefficients, &tables.page1_iono, &self.iono, ctx, &w);
                try field.encode(Eph, &tables.page1_tail, &sv.eph, ctx, &w);
            } else return dummy_page,
            .ephemeris_1 => try field.encode(Eph, &tables.page2, &sv.eph, ctx, &w),
            .ephemeris_2 => try field.encode(Eph, &tables.page3, &sv.eph, ctx, &w),
            .ephemeris_3 => if (self.utc) |*utc| {
                try field.encode(Eph, &tables.page4, &sv.eph, ctx, &w);
                try field.encode(time_parameters.Utc, &tables.page4_utc, utc, ctx, &w);
                try field.encode(time_parameters.Ggto, &tables.page4_tail, &self.ggto, ctx, &w);
            } else return dummy_page,
            .almanac_1 => try field.encode(almanac_fields.Group, &tables.page5, &self.groups[group], ctx, &w),
            .almanac_2 => try field.encode(almanac_fields.Group, &tables.page6, &self.groups[group], ctx, &w),
        }
        return out;
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.sv[prn - 1] != null;
    }
};

const dummy_page_type = 63;

const dummy_page: PageContent = blk: {
    var content: PageContent = .{};
    var w = content.writer();
    w.writeBits(6, dummy_page_type);
    break :blk content;
};

/// F/NAV's content for a leg: the reference projected onto F/NAV's clock, and whether page 1 can carry that clock.
pub fn prepare(e: reference.Kepler) Content {
    const eph = projection.forSource(e, .fnav);
    return .{ .carried = .{
        .eph = eph,
        .clock_fits = clockAvailable(e) and field.fits(Eph, &tables.page1, &eph) and field.fits(Eph, &tables.page1_tail, &eph),
    } };
}

pub fn valid(sv: *const Sv, sat: SatId) bool {
    if (sv.eph.sat != sat or sv.eph.extra != .fnav) return false;
    if (sv.clock_fits and !(field.fits(Eph, &tables.page1, &sv.eph) and field.fits(Eph, &tables.page1_tail, &sv.eph))) return false;
    inline for (.{ &tables.page2, &tables.page3, &tables.page4 }) |rows| if (!field.fits(Eph, rows, &sv.eph)) return false;
    return true;
}

fn clockAvailable(e: reference.Kepler) bool {
    return e.record.source() == .fnav or (e.group_delay.contains(.bgd_e1e5a) and e.group_delay.contains(.bgd_e1e5b));
}

fn almanacGroup(group: u4, prn: u8) u4 {
    return @intCast((@as(u32, group) + prn - 1) % almanac_groups);
}

fn buildContent(set: *const Set, prn: u8, index: i64) ?PageContent {
    const sv = if (set.sv[prn - 1]) |*entry| entry else return null;
    const s = slot(index);
    return set.pageBits(sv, s.page, almanacGroup(s.group, prn), .{ .wn = s.wn, .tow = s.tow }) catch unreachable;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const content = buildContent(set, prn, index) orelse return null;
    return page.encode(&content);
}
