const std = @import("std");
const types = @import("../../core.zig").types;
const time = @import("../../core.zig").time;
const iono = @import("../../core.zig").iono;
const field = @import("../../codec.zig").field;
const records = @import("../records.zig");
const Kepler = @import("../reference.zig").Kepler;
const auxiliary = @import("../auxiliary.zig");
const bds_records = @import("records.zig");
const health = @import("../health.zig");
const almanac_reference = @import("../almanac_reference.zig");
const sources = @import("d1d2/sources.zig");
const pages = @import("d1d2/pages.zig");
pub const almanacMisfit = pages.almanacMisfit;
const tables = @import("d1d2/tables.zig");
pub const misfit = tables.misfit;
const fit = @import("d1d2/fit.zig");
pub const integrity = @import("d1d2/integrity.zig");
pub const grid = @import("d1d2/grid.zig");
pub const augmentation = @import("d1d2/augmentation.zig");
const word = @import("d1d2/word.zig");

const Parameters = @import("../kepler_parameters.zig").Parameters;
const Alm = records.KeplerAlmanac;
const GpsTime = time.GpsTime;

const schedule = @import("d1d2/schedule.zig");
pub const toe_step_ms = sources.toe_step_ms;
pub const d2_pages_per_superframe = schedule.d2_pages_per_superframe;

const d1_frame_ms = schedule.d1_frame_ms;
pub const d2_frame_ms = schedule.d2_frame_ms;
pub const frame_ms = d1_frame_ms;
pub const bits_per_frame = word.frame_bits;
pub const Frame = word.Frame;
const Info = word.Info;
const Error = field.Error;
const Content = schedule.Content;
const Navigation = schedule.Navigation;

pub const Carrier = enum {
    b1i,
    b2i,
    b3i,

    pub fn of(signal: types.Signal) Carrier {
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

const isGeo = bds_records.isGeo;
const d1Slot = schedule.d1Slot;
const d2Slot = schedule.d2Slot;
const d1Content = schedule.d1Content;
const d2Content = schedule.d2Content;

pub const Interval = fit.Interval;
pub const Flight = struct { record: Kepler, interval: Interval };
pub const FieldFailure = tables.FieldFailure;

pub const Prepared = struct {
    parameters: Parameters,
    metadata: sources.Metadata,
    decoded: Parameters,

    fn sv(self: *const Prepared, k: iono.klobuchar.Model) sources.Sv {
        return .{ .eph = self.parameters, .metadata = self.metadata, .klobuchar = .of(k) };
    }

    pub fn valid(self: *const Prepared, planned: Kepler) bool {
        const source = planned.record;
        if (!std.meta.eql(self.parameters.sat, source.sat)) return false;
        if (self.parameters.misfit() != null) return false;
        if (self.parameters.a_dot != 0 or self.parameters.delta_n_dot != 0) return false;
        if (!self.parameters.toe.eql(tables.floorTo8s(source.toe)) or
            !self.parameters.toc.eql(tables.floorTo8s(source.toc))) return false;

        const original = source.parameters();
        if (fit.carried(&original)) {
            if (!std.meta.eql(self.parameters, original)) return false;
        } else {
            const clock = source.clock();
            if (self.parameters.af0 != clock.bias(self.parameters.toc) or
                self.parameters.af1 != clock.drift(self.parameters.toc) or
                self.parameters.af2 != source.af2) return false;
        }

        if (!std.meta.eql(self.metadata, sources.metadata(planned, &self.parameters))) return false;
        const value = self.sv(.zero);
        const decoded = tables.decoded(&value) orelse return false;
        return std.meta.eql(self.decoded, decoded);
    }
};

pub const Preparation = union(enum) {
    fit_failed,
    unrepresentable: FieldFailure,
    ready: Prepared,
};

pub fn prepare(flight: Flight) Preparation {
    const source = flight.record.record.parameters();
    const parameters = if (fit.carried(&source)) source else fit.fitted(&source, flight.interval) orelse return .fit_failed;
    const metadata = sources.metadata(flight.record, &parameters);
    const sv: sources.Sv = .{ .eph = parameters, .metadata = metadata, .klobuchar = .of(.zero) };
    if (tables.failure(&sv)) |failed| return .{ .unrepresentable = failed };
    return .{ .ready = .{ .parameters = parameters, .metadata = metadata, .decoded = tables.decoded(&sv).? } };
}

pub const Set = struct {
    sv: [63]?sources.Sv,
    alm: [63]?Alm,
    hea: [63]u9,
    wna: u8,
    toa: u8,
    utc: ?pages.UtcPage,
    offsets: ?pages.OffsetPage,
    service: ?augmentation.Source = null,
    epoch: GpsTime,

    pub const Inputs = struct {
        eph: [63]?*const Prepared,
        almanacs: []const Alm,
        klobuchar: iono.klobuchar.Model,
        utc: ?auxiliary.UtcParams,
        offsets: [3]?auxiliary.TimeOffset = @splat(null),
        service: ?augmentation.Source = null,
        t: GpsTime,
    };

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.* = .{
            .sv = @splat(null),
            .alm = @splat(null),
            .hea = @splat(health.almanac_health_all),
            .wna = 0,
            .toa = 0,
            .utc = pages.utcFromParams(in.utc, in.t),
            .offsets = pages.offsetsFromParams(in.offsets, in.t),
            .service = in.service,
            .epoch = in.t,
        };

        for (in.eph, 0..) |entry, i| if (entry) |prepared| {
            set.sv[i] = prepared.sv(in.klobuchar);
        };

        var reference: ?Alm = null;
        for (in.almanacs) |a| {
            if (reference) |r| if (!a.toa.eql(r.toa)) continue;
            if (!pages.representable(a, isGeo(a.sat.prn()))) continue;
            const i = a.sat.prn() - 1;
            set.alm[i] = a;
            set.hea[i] = a.health;
            if (reference == null) reference = a;
        }

        const toa = if (reference) |a| a.toa else in.t;
        const bdt = toa.inScale(.bds);
        set.wna = @intCast(@mod(bdt.period, time.week_modulus_8));
        set.toa = @intCast(bdt.ms / almanac_reference.toa_step_ms);
        try set.validate();
    }

    fn validate(self: *const Set) Error!void {
        for (&self.sv, 1..) |*entry, number| {
            if (entry.* == null) continue;
            const prn: u8 = @intCast(number);
            const parts: []const schedule.Ephemeris = if (isGeo(prn)) &schedule.d2_pages else &schedule.d1_subframes;
            for (parts) |part| _ = try self.infoBits(prn, .{ .ephemeris = part }, .{}, self.epoch);
        }
        if (self.offsets != null) _ = try self.infoBits(1, .{ .offsets = 9 }, .{}, self.epoch);
        if (self.utc != null) _ = try self.infoBits(1, .{ .utc = 10 }, .{}, self.epoch);
    }

    fn healthPage(self: *const Set, pnum: u7, first: usize, count: usize, am_id: u2) pages.HealthPage {
        var page: pages.HealthPage = .{ .pnum = pnum, .hea = @splat(0), .wna = self.wna, .toa = self.toa, .am_id = am_id };
        for (0..count) |k| page.hea[k] = self.hea[first + k];
        return page;
    }

    fn infoBits(self: *const Set, prn: u8, content: Navigation, ctx: tables.Ctx, t: GpsTime) Error!Info {
        var out: Info = .{};
        var w = out.writer();
        const dt: f64 = @floatFromInt((t.inScale(.bds).period - self.epoch.inScale(.bds).period) * time.s_per_week);
        switch (content) {
            .ephemeris => |part| {
                const sv = self.sv[prn - 1].?.at(t);
                switch (part) {
                    inline else => |p| try field.encode(sources.Sv, &@field(tables, @tagName(p)), &sv, ctx, &w),
                }
            },
            .almanac => |a| {
                const page: pages.AlmPage = .{ .alm = self.alm[a.slot], .pnum = a.pnum, .am_id = a.am_id, .geo = isGeo(@as(u8, a.slot) + 1) };
                try field.encode(pages.AlmPage, &pages.almanac, &page, ctx, &w);
            },
            .health7 => |pnum| try field.encode(pages.HealthPage, &pages.health7, &self.healthPage(pnum, 0, 19, 0), ctx, &w),
            .health8 => |pnum| try field.encode(pages.HealthPage, &pages.health8, &self.healthPage(pnum, 19, 11, 0), ctx, &w),
            .health24 => |h| {
                const first: usize = 30 + 13 * (@as(usize, h.am_id) - 1);
                try field.encode(pages.HealthPage, &pages.health24, &self.healthPage(h.pnum, first, if (h.am_id == 3) 7 else 13, h.am_id), ctx, &w);
            },
            .offsets => |pnum| {
                var page = self.offsets.?;
                page.pnum = pnum;
                page.a0gps += page.a1gps * dt;
                page.a0gal += page.a1gal * dt;
                page.a0glo += page.a1glo * dt;
                try field.encode(pages.OffsetPage, &pages.offsets, &page, ctx, &w);
            },
            .utc => |pnum| {
                var page = self.utc.?;
                page.pnum = pnum;
                page.a0 += page.a1 * dt;
                try field.encode(pages.UtcPage, &pages.utc, &page, ctx, &w);
            },
            .reserved => |r| try field.encode(pages.Filler, &pages.reserved_page, &pages.Filler{ .pnum = r.pnum, .am_id = r.am_id }, ctx, &w),
        }
        return out;
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.sv[prn - 1] != null and self.utc != null;
    }
};

pub fn requireData(set: *const Set, prn: u8) error{MissingUtcParameters}!void {
    if (set.sv[prn - 1] != null and set.utc == null) return error.MissingUtcParameters;
}

pub fn setCycle(prn: u8, index: i64) i64 {
    return @divFloor(index, @divExact(schedule.cycle_ms, subframeMs(prn)));
}

fn subframeMs(prn: u8) i64 {
    return if (isGeo(prn)) d2_frame_ms else d1_frame_ms;
}

pub fn cycleStart(t: GpsTime) GpsTime {
    return GpsTime.fromBaseMs(.bds, @divFloor(t.baseMs(.bds, .table), schedule.cycle_ms) * schedule.cycle_ms, .table);
}

const Slot = struct { subframe: u3, sow: u20, content: Content };

fn slot(prn: u8, index: i64) Slot {
    if (isGeo(prn)) {
        const s = d2Slot(index);
        return .{ .subframe = s.subframe, .sow = s.sow, .content = d2Content(s) };
    }
    const s = d1Slot(index);
    return .{ .subframe = s.subframe, .sow = s.sow, .content = .{ .navigation = d1Content(s) } };
}

fn augmentationInfo(set: *const Set, prn: u8, index: i64, content: schedule.Augmentation, ctx: tables.Ctx, carrier: Carrier) Info {
    const frame = if (set.service) |service| service.frame(prn, @divFloor(index, 5)) else null;
    switch (content) {
        .integrity => |p| {
            var block = if (frame) |f| f.integrity else integrity.Block.none;
            if (carrier == .b2i) block = block.narrowed();
            return integrity.encode(&block, p.subframe, p.page, ctx.sow_lsb);
        },
        .grid => |pnum| {
            const page = (if (frame) |f| f.grid else null) orelse augmentation.gridPage(null, pnum, null);
            return grid.encode(&page, ctx.sow_lsb);
        },
    }
}

fn buildInfo(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Info {
    if (!set.hasRecord(prn)) return null;
    const f = slot(prn, index);
    const ctx = tables.Ctx{ .sow_lsb = @truncate(f.sow) };
    const content = switch (f.content) {
        .navigation => |n| n,
        .augmentation => |a| return augmentationInfo(set, prn, index, a, ctx, carrier),
    };
    if (set.offsets == null and content == .offsets) return null;
    const t = GpsTime.fromBaseMs(.bds, index * subframeMs(prn), .table);
    if (content == .utc or content == .offsets) return set.infoBits(prn, content, ctx, t) catch null;
    return set.infoBits(prn, content, ctx, t) catch unreachable;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    const info = buildInfo(set, prn, index, carrier) orelse return null;
    const f = slot(prn, index);
    return word.encodeSubframe(f.subframe, f.sow, &info);
}
