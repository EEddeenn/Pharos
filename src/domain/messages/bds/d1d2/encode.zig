const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const bds_records = @import("domain/navigation/records/bds");
const pages = @import("domain/messages/bds/d1d2/pages");
const fields = @import("domain/messages/bds/d1d2/fields");
const word = @import("domain/messages/bds/d1d2/word");
const schedule = @import("domain/messages/bds/d1d2/schedule");
const integrity = @import("domain/messages/bds/d1d2/integrity");
const grid = @import("domain/messages/bds/d1d2/grid");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const Set = @import("domain/messages/bds/d1d2/set").Set;
const GpsTime = time.GpsTime;
const d1_frame_ms = schedule.d1_frame_ms;
const Info = word.Info;
const Error = field.Error;
const Scheduled = schedule.Content;
const Navigation = schedule.Navigation;
const isGeo = bds_records.isGeo;
const d1Slot = schedule.d1Slot;
const d2Slot = schedule.d2Slot;
const d1Content = schedule.d1Content;
const d2Content = schedule.d2Content;

pub const Carrier = enum {
    b1i,
    b2i,
    b3i,

    pub fn of(signal: gnss_types.Signal) Carrier {
        return switch (signal) {
            .b1i => .b1i,
            .b2i => .b2i,
            .b3i => .b3i,
            else => unreachable,
        };
    }

    pub fn frameMs(_: Carrier) u32 {
        return d1_frame_ms;
    }
};

pub const frame_ms = d1_frame_ms;
pub const d2_frame_ms = schedule.d2_frame_ms;
pub const d2_pages_per_superframe = schedule.d2_pages_per_superframe;
pub const bits_per_frame = word.frame_bits;
pub const Frame = word.Frame;

const Slot = struct { subframe: u3, sow: u20, content: Scheduled };

pub fn setCycle(prn: u8, index: i64) i64 {
    return @divFloor(index, @divExact(schedule.cycle_ms, subframeMs(prn)));
}

pub fn cycleStart(t: GpsTime) GpsTime {
    return GpsTime.fromBaseMs(.bds, @divFloor(t.baseMs(.bds, .table), schedule.cycle_ms) * schedule.cycle_ms, .table);
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    const info = buildInfo(set, prn, index, carrier) orelse return null;
    const f = slot(prn, index);
    return word.encodeSubframe(f.subframe, f.sow, &info);
}

fn healthPage(self: *const Set, pnum: u7, first: usize, count: usize, am_id: u2) pages.HealthPage {
    var page: pages.HealthPage = .{ .pnum = pnum, .hea = @splat(0), .wna = self.almanacs.wna, .toa = self.almanacs.toa, .am_id = am_id };
    for (0..count) |k| page.hea[k] = self.almanacs.health[first + k];
    return page;
}

fn infoBits(self: *const Set, prn: u8, content: Navigation, ctx: fields.Ctx, t: GpsTime) Error!Info {
    var out: Info = .{};
    var w = out.writer();
    const dt: f64 = @floatFromInt((t.inScale(.bds).period - self.system.?.epoch.inScale(.bds).period) * time.s_per_week);
    switch (content) {
        .ephemeris => |part| {
            const codes = self.sv[prn - 1].?.at(t);
            switch (part) {
                inline else => |p| fields.write(&@field(fields, @tagName(p)), codes, self.system.?.klobuchar, ctx, &w),
            }
        },
        .almanac => |a| {
            const page: pages.AlmPage = .{ .alm = self.almanacs.entries[a.slot], .pnum = a.pnum, .am_id = a.am_id, .geo = isGeo(@as(u8, a.slot) + 1) };
            try field.encode(pages.AlmPage, &pages.almanac, &page, ctx, &w);
        },
        .health7 => |pnum| try field.encode(pages.HealthPage, &pages.health7, &healthPage(self, pnum, 0, 19, 0), ctx, &w),
        .health8 => |pnum| try field.encode(pages.HealthPage, &pages.health8, &healthPage(self, pnum, 19, 11, 0), ctx, &w),
        .health24 => |h| {
            const first: usize = 30 + 13 * (@as(usize, h.am_id) - 1);
            try field.encode(pages.HealthPage, &pages.health24, &healthPage(self, h.pnum, first, if (h.am_id == 3) 7 else 13, h.am_id), ctx, &w);
        },
        .offsets => |pnum| try field.encode(pages.Filler, &pages.zero_offsets, &.{ .pnum = pnum }, ctx, &w),
        .utc => |pnum| {
            var page = self.system.?.utc;
            page.pnum = pnum;
            page.a0 += page.a1 * dt;
            try field.encode(pages.UtcPage, &pages.utc, &page, ctx, &w);
        },
        .reserved => |r| try field.encode(pages.Filler, &pages.reserved_page, &pages.Filler{ .pnum = r.pnum, .am_id = r.am_id }, ctx, &w),
    }
    return out;
}

fn subframeMs(prn: u8) i64 {
    return if (isGeo(prn)) d2_frame_ms else d1_frame_ms;
}

fn slot(prn: u8, index: i64) Slot {
    if (isGeo(prn)) {
        const s = d2Slot(index);
        return .{ .subframe = s.subframe, .sow = s.sow, .content = d2Content(s) };
    }
    const s = d1Slot(index);
    return .{ .subframe = s.subframe, .sow = s.sow, .content = .{ .navigation = d1Content(s) } };
}

fn augmentationInfo(set: *const Set, prn: u8, index: i64, content: schedule.Augmentation, ctx: fields.Ctx, carrier: Carrier) Info {
    _ = prn;
    const frame_index = @divFloor(index, 5);
    const frame = if (set.service) |service| service.read(frame_index) else null;
    const transmitted = GpsTime.fromBaseMs(.bds, frame_index * 3000, .table);
    const declaration = if (augmentation.PreparedPublication.at(set.publications, transmitted)) |p| &p.content else null;
    switch (content) {
        .integrity => |p| {
            const empty: [integrity.max_packets]?f64 = @splat(null);
            var block = augmentation.block(declaration, if (frame) |*f| &f.corrections else &empty);
            if (carrier == .b2i) block = block.narrowed();
            return integrity.encode(&block, p.subframe, p.page, ctx.sow_lsb);
        },
        .grid => |pnum| {
            const codes: ?*const [grid.points_per_page]u9 = if (frame) |*f| if (f.grid) |*g| g else null else null;
            const page = augmentation.gridPage(declaration, pnum, codes);
            return grid.encode(&page, ctx.sow_lsb);
        },
    }
}

fn buildInfo(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Info {
    if (!set.hasRecord(prn)) return null;
    const f = slot(prn, index);
    const ctx = fields.Ctx{ .sow_lsb = @truncate(f.sow) };
    const content = switch (f.content) {
        .navigation => |n| n,
        .augmentation => |a| return augmentationInfo(set, prn, index, a, ctx, carrier),
    };
    const t = GpsTime.fromBaseMs(.bds, index * subframeMs(prn), .table);
    if (content == .utc) return infoBits(set, prn, content, ctx, t) catch null;
    return infoBits(set, prn, content, ctx, t) catch unreachable;
}
