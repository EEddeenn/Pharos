const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const geo = @import("shared").geo;
const common = @import("common.zig");
const inputs = @import("shared").stage.messages.inputs;
const types = core.types;
const GpsTime = core.time.GpsTime;
const d1d2 = gnss.bds.d1d2;
const augmentation = d1d2.augmentation;
const grid = d1d2.grid;

const d2_superframe_s = 360;

const ring_len = 16;
const lead_ms = 3000;

pub const Stream = struct {
    b: *const bundle.Bundle,
    allocation: *const gnss.allocation.Allocation,
    publications: []const augmentation.PreparedPublication,
    model: *const core.iono.Model,
    source: common.Source,
    cadence: common.Cadence,
    ring: common.Ring(augmentation.Frame, ring_len) = .{},
    superframe: ?i64 = null,
    delays: [grid.igp_count]u9 = undefined,

    pub fn init(self: *Stream, b: *const bundle.Bundle, allocation: *const gnss.allocation.Allocation, publications: []const augmentation.PreparedPublication, model: *const core.iono.Model) void {
        self.* = .{ .b = b, .allocation = allocation, .publications = publications, .model = model, .source = .{ .b = b, .scale = .bds }, .cadence = .init(core.time.bds_offset_ms, b.scenario.start.addMs(-lead_ms)) };
    }

    pub fn reset(self: *Stream) void {
        self.init(self.b, self.allocation, self.publications, self.model);
    }

    pub fn advanceTo(self: *Stream, second: i64) void {
        var walk = self.cadence.upTo(second);
        while (walk.next()) |s| {
            if (self.cadence.isFirst() or @mod(s, 3) == 0) self.produce(@divFloor(s, 3));
        }
    }

    fn produce(self: *Stream, index: i64) void {
        const t = self.cadence.timeOf(3 * index);
        const published = if (augmentation.PreparedPublication.at(self.publications, t)) |p| &p.content else null;
        var corrections: [d1d2.integrity.max_packets]?f64 = @splat(null);
        if (published) |p| if (p.integrity) |list| {
            const at = self.source.notBefore(t);
            const rx = geo.receiver.at(&self.b.trajectory, at.secondsSince(self.b.scenario.start));
            for (list.svid[0..list.count], corrections[0..list.count]) |svid, *c| {
                c.* = self.equivalentClock(types.SatId.at(.bds, svid - 1), at, rx.pos);
            }
        };

        const pnum: u7 = @intCast(@mod(index, d1d2.d2_pages_per_superframe) + 1);
        const has_grid = if (published) |p| p.grid != null else false;
        var page: ?grid.Page = null;
        if (grid.isPage(pnum)) {
            const superframe_index = @divFloor(index, d1d2.d2_pages_per_superframe);
            const delay_codes = if (has_grid) self.delaysOf(superframe_index) else null;
            page = augmentation.gridPage(published, pnum, delay_codes);
        }

        self.ring.put(index, .{ .integrity = augmentation.block(published, &corrections), .grid = page });
        self.cadence.generated += 1;
    }

    fn equivalentClock(self: *Stream, sat: types.SatId, t: GpsTime, rx: core.coord.Ecef) ?f64 {
        const flight = inputs.d1d2Reference(self.b, self.allocation, sat, self.source.notBefore(d1d2.cycleStart(t))) orelse return null;
        const c = self.source.correctionAgainst(sat, flight.record, &flight.prepared.decoded, t, .icd_periodic) orelse return null;
        const m = c.equivalentClock(rx);
        return if (std.math.isFinite(m)) m else null;
    }

    fn delaysOf(self: *Stream, n: i64) *const [grid.igp_count]u9 {
        if (self.superframe != n) {
            const t = self.cadence.timeOf(d2_superframe_s * n);
            const to_b1i = gnss.spec.get(.b1i).ionoFactor(null);
            for (&self.delays, &grid.points) |*code, point| code.* = grid.delayCode(self.model.verticalL1(t, point) * to_b1i);
            self.superframe = n;
        }
        return &self.delays;
    }

    pub fn frame(self: *const Stream, _: u8, index: i64) ?augmentation.Frame {
        return self.ring.get(index);
    }
};
