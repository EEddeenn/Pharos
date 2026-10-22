const time = @import("domain/time/gps");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const trajectory = @import("domain/trajectory/trajectory");
const integrity = @import("domain/messages/bds/d1d2/integrity");
const receiver = @import("simulation/geometry/receiver");
const coordinates = @import("domain/earth/coordinates");
const signal_catalog = @import("domain/signals/catalog");
const cadence = @import("products/run/services/cadence");
const reference_tracks = @import("products/run/services/reference_tracks");
const ring_buffer = @import("products/run/services/ring");
const binding = @import("simulation/tracking/binding");
const gnss_types = @import("domain/gnss_types");
const d1d2_schedule = @import("domain/messages/bds/d1d2/schedule");
const d1d2_encode = @import("domain/messages/bds/d1d2/encode");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const grid = @import("domain/messages/bds/d1d2/grid");

const GpsTime = time.GpsTime;

const frame_s = 3;
const superframe_s = frame_s * d1d2_schedule.d2_pages_per_superframe;

const ring_len = 16;
const lead_ms = 3000;

pub const Stream = struct {
    publications: []const augmentation.PreparedPublication,
    model: *const ionosphere_model.Model,
    source: reference_tracks.Source,
    start: GpsTime,
    trajectory: *const trajectory.Trajectory,
    cadence: cadence.Cadence,
    ring: ring_buffer.Ring(augmentation.CorrectionPayload, ring_len) = .{},
    superframe: ?i64 = null,
    delays: [grid.igp_count]u9 = undefined,

    pub fn init(self: *Stream, ephemerides: binding.Inputs, start: GpsTime, receiver_trajectory: *const trajectory.Trajectory, publications: []const augmentation.PreparedPublication, model: *const ionosphere_model.Model) void {
        self.* = .{ .publications = publications, .model = model, .start = start, .trajectory = receiver_trajectory, .source = .{ .ephemerides = ephemerides, .scale = .bds }, .cadence = .init(time.bds_offset_ms, start.addMs(-lead_ms)) };
    }

    pub fn reset(self: *Stream) void {
        self.init(self.source.ephemerides, self.start, self.trajectory, self.publications, self.model);
    }

    pub fn advanceTo(self: *Stream, t: GpsTime) void {
        while (self.cadence.next(t)) |s| {
            if (s == self.cadence.first or @mod(s, frame_s) == 0) self.produce(@divFloor(s, frame_s));
        }
    }

    pub fn read(self: *const Stream, index: i64) ?augmentation.CorrectionPayload {
        return self.ring.get(index);
    }

    fn produce(self: *Stream, index: i64) void {
        const t = self.cadence.timeOf(frame_s * index);
        const published = if (augmentation.PreparedPublication.at(self.publications, t)) |p| &p.content else null;
        var corrections: [integrity.max_packets]?f64 = @splat(null);
        if (published) |p| if (p.integrity) |list| {
            const at = self.source.notBefore(t);
            const rx = receiver.at(self.trajectory, at.secondsSince(self.start));
            for (list.svid[0..list.count], corrections[0..list.count]) |svid, *c| {
                c.* = self.equivalentClock(gnss_types.SatId.at(.bds, svid - 1), at, rx.pos);
            }
        };

        const pnum: u7 = @intCast(@mod(index, d1d2_schedule.d2_pages_per_superframe) + 1);
        const has_grid = if (published) |p| p.grid != null else false;
        var page: ?[13]u9 = null;
        if (grid.isPage(pnum) and has_grid) {
            const superframe_index = @divFloor(index, d1d2_schedule.d2_pages_per_superframe);
            const delay_codes = self.delaysOf(superframe_index);
            const points = grid.igpsOf(pnum);
            var values: [13]u9 = @splat(grid.not_available);
            const first: usize = points.first - 1;
            @memcpy(values[0..points.count], delay_codes[first..][0..points.count]);
            page = values;
        }
        self.ring.put(index, .{ .corrections = corrections, .grid = page });
    }

    fn equivalentClock(self: *Stream, sat: gnss_types.SatId, t: GpsTime, rx: coordinates.Ecef) ?f64 {
        const content = self.source.contentAt(sat, .d1d2, d1d2_encode.cycleStart(t)) orelse return null;
        const prepared = content.d1d2.value() orelse return null;
        const c = self.source.correctionAgainst(sat, &prepared.decoded, t, .icd_periodic) orelse return null;
        return c.equivalentClock(rx);
    }

    fn delaysOf(self: *Stream, n: i64) *const [grid.igp_count]u9 {
        if (self.superframe != n) {
            const t = self.cadence.timeOf(superframe_s * n);
            const to_b1i = signal_catalog.get(.b1i).ionoFactor(null);
            for (&self.delays, &grid.points) |*code, point| code.* = grid.delayCode(self.model.verticalL1(t, point) * to_b1i);
            self.superframe = n;
        }
        return &self.delays;
    }
};
