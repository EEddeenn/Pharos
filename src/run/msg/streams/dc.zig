const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const track = @import("shared").track;
const common = @import("common.zig");
const dc = gnss.gps.dc;
const types = core.types;
const GpsTime = core.time.GpsTime;
const Reference = gnss.reference.Kepler;

const ring_len = 16;
const samples_len = 8;

const Fit = struct { correction: dc.Correction, binding: *const bundle.plan.Binding };

const Entry = struct {
    t_od: GpsTime,
    fits: [32]?Fit = @splat(null),
};

const Sample = struct { state: dc.fit.Sample, record: Reference };

pub const Stream = struct {
    source: common.Source,
    first: GpsTime,
    next: GpsTime,
    sampler: track.provider.Cursor,
    ring: common.Ring(Entry, ring_len) = .{},
    samples: [32][samples_len]?Sample = @splat(@splat(null)),

    pub fn init(self: *Stream, b: *const bundle.Bundle) void {
        const first = dc.epochOf(b.scenario.start);
        self.* = .{ .source = .{ .b = b, .scale = .gps }, .first = first, .next = first, .sampler = .init(.gps, b.plan.start, b.plan.leap) };
    }

    pub fn reset(self: *Stream) void {
        self.init(self.source.b);
    }

    pub fn advanceTo(self: *Stream, t: GpsTime) void {
        while (!t.lessThan(self.next)) : (self.next = self.next.addMs(dc.epoch_ms)) {
            self.sampleThrough(self.sampleTime(self.next.addMs(dc.epoch_ms)));
            self.ring.put(epochIndex(self.next), self.compute(self.next));
        }
    }

    fn epochIndex(epoch: GpsTime) i64 {
        return @divFloor(epoch.ms, dc.epoch_ms);
    }

    fn sampleTime(self: *const Stream, t: GpsTime) GpsTime {
        return .{ .ms = t.ms, .sub_ms = self.source.b.plan.start.sub_ms };
    }

    fn sampleSlot(t: GpsTime) usize {
        return @intCast(@mod(@divFloor(t.ms, bundle.plan.grid_ms), samples_len));
    }

    fn sampleThrough(self: *Stream, end: GpsTime) void {
        while (self.sampler.next(end)) |t| {
            var sats = types.System.gps.satellites();
            while (sats.next()) |sat| {
                const slot = &self.samples[sat.prn() - 1][sampleSlot(t)];
                const c = self.source.correctionOf(sat, t, .icd_periodic) orelse {
                    slot.* = null;
                    continue;
                };
                slot.* = .{ .state = .{ .t = t, .pos = c.brdc_pos.add(c.delta_pos).toArray(), .clock_s = c.clock_delta_m / core.constants.light_speed }, .record = c.record };
            }
        }
    }

    fn compute(self: *const Stream, epoch: GpsTime) Entry {
        const b = self.source.b;
        const start = if (epoch.lessThan(b.plan.start)) b.plan.start else self.sampleTime(epoch);
        const end = self.sampleTime(epoch.addMs(dc.epoch_ms));
        var out: Entry = .{ .t_od = epoch };
        for (&self.samples, 0..) |*ring, i| {
            const sat = types.SatId.at(.gps, i);
            const binding = b.plan.bindingAt(sat, start) orelse continue;
            const head = ring[sampleSlot(start)] orelse continue;
            if (!head.state.t.eql(start) or head.record.record.source() != .lnav) continue;
            var states: [samples_len]dc.fit.Sample = undefined;
            var n: usize = 0;
            var times: track.provider.Cursor = .init(.gps, start, b.plan.leap);
            while (times.next(end)) |t| {
                const s = ring[sampleSlot(t)] orelse break;
                if (!s.state.t.eql(t) or !std.meta.eql(s.record, head.record)) break;
                states[n] = s.state;
                n += 1;
            }
            const record = gnss.gps.lnav.described(head.record);
            const corr = dc.fit.correction(&record, epoch, states[0..n]) orelse continue;
            if (!dc.representable(corr)) continue;
            out.fits[i] = .{ .correction = corr, .binding = binding };
        }
        return out;
    }

    pub fn batch(self: *const Stream, t_od: GpsTime, t: GpsTime) ?dc.Batch {
        const plan = &self.source.b.plan;
        const epoch = if (t_od.lessThan(self.first)) self.first else t_od;
        const entry = self.ring.get(epochIndex(epoch)) orelse return null;
        if (!entry.t_od.eql(epoch)) return null;
        const at = self.source.notBefore(t);
        var out: dc.Batch = .{ .t_od = entry.t_od };
        for (&out.corrections, entry.fits, 0..) |*c, fit, i| {
            const f = fit orelse continue;
            const now = plan.bindingAt(types.SatId.at(.gps, i), at) orelse continue;
            if (now == f.binding) c.* = f.correction;
        }
        return out;
    }
};
