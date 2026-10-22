const flight = @import("simulation/model/flight_plan");
const kepler_parameters = @import("domain/navigation/orbit/parameters");
const tracking = @import("simulation/tracking/track");
const reference_tracks = @import("products/run/services/reference_tracks");
const ring_buffer = @import("products/run/services/ring");
const binding = @import("simulation/tracking/binding");
const dc = @import("domain/messages/gps/differential");
const fitting = @import("products/run/services/gps_dc/fit");
const gnss_types = @import("domain/gnss_types");
const physical = @import("domain/physical_constants");

const GpsTime = @import("domain/time/gps").GpsTime;

const ring_len = 16;
const samples_len = 8;

const Fit = struct { correction: dc.Correction, binding_start: flight.LegId };

const Entry = [32]?Fit;

/// A sample of the truth against the LNAV a satellite's leg carries.
const Sample = struct { state: fitting.Sample, lnav: *const kepler_parameters.Parameters, binding_start: flight.LegId };

pub const Stream = struct {
    source: reference_tracks.Source,
    start: GpsTime,
    first: GpsTime,
    next: GpsTime,
    sampler: tracking.Cursor,
    ring: ring_buffer.Ring(Entry, ring_len) = .{},
    samples: [32][samples_len]?Sample = @splat(@splat(null)),

    pub fn init(self: *Stream, ephemerides: binding.Inputs, start: GpsTime) void {
        const first = dc.epochOf(start);
        self.* = .{ .start = start, .source = .{ .ephemerides = ephemerides, .scale = .gps }, .first = first, .next = first, .sampler = .init(.gps, ephemerides.flight_plan.start, ephemerides.flight_plan.leap) };
    }

    pub fn reset(self: *Stream) void {
        self.init(self.source.ephemerides, self.start);
    }

    pub fn advanceTo(self: *Stream, t: GpsTime) void {
        while (!t.lessThan(self.next)) : (self.next = self.next.addMs(dc.epoch_ms)) {
            self.sampleThrough(self.sampleTime(self.next.addMs(dc.epoch_ms)));
            self.ring.put(epochIndex(self.next), self.compute(self.next));
        }
    }

    pub fn batch(self: *const Stream, t_od: GpsTime, t: GpsTime) ?dc.Batch {
        const plan = self.source.ephemerides.flight_plan;
        const epoch = if (t_od.lessThan(self.first)) self.first else t_od;
        const entry = self.ring.get(epochIndex(epoch)) orelse return null;
        const at = self.source.notBefore(t);
        var out: dc.Batch = .{ .t_od = epoch };
        for (&out.corrections, entry, 0..) |*c, fit, i| {
            const f = fit orelse continue;
            const now = plan.bindingStartAt(gnss_types.SatId.at(.gps, i), at) orelse continue;
            if (now.eql(f.binding_start)) c.* = f.correction;
        }
        return out;
    }

    fn epochIndex(epoch: GpsTime) i64 {
        return @divFloor(epoch.ms, dc.epoch_ms);
    }

    fn sampleTime(self: *const Stream, t: GpsTime) GpsTime {
        return .{ .ms = t.ms, .sub_ms = self.source.ephemerides.flight_plan.start.sub_ms };
    }

    fn sampleSlot(t: GpsTime) usize {
        return @intCast(@mod(@divFloor(t.ms, flight.grid_ms), samples_len));
    }

    fn sampleThrough(self: *Stream, end: GpsTime) void {
        while (self.sampler.next(end)) |t| {
            var sats = gnss_types.System.gps.satellites();
            while (sats.next()) |sat| {
                const slot = &self.samples[sat.prn() - 1][sampleSlot(t)];
                slot.* = null;
                const content = self.source.contentAt(sat, .lnav, t) orelse continue;
                const lnav = content.lnav.value() orelse continue;
                const c = self.source.correctionAgainst(sat, &lnav.eph, t, .icd_periodic) orelse continue;
                slot.* = .{ .state = .{ .t = t, .pos = c.brdc_pos.add(c.delta_pos).toArray(), .clock_s = c.clock_delta_m / physical.light_speed }, .lnav = &lnav.eph, .binding_start = self.source.bindingStartAt(sat, t).? };
            }
        }
    }

    fn compute(self: *const Stream, epoch: GpsTime) Entry {
        const flight_plan = self.source.ephemerides.flight_plan;
        const start = if (epoch.lessThan(flight_plan.start)) flight_plan.start else self.sampleTime(epoch);
        const end = self.sampleTime(epoch.addMs(dc.epoch_ms));
        var out: Entry = @splat(null);
        for (&self.samples, 0..) |*ring, i| {
            const sat = gnss_types.SatId.at(.gps, i);
            const binding_start = flight_plan.bindingStartAt(sat, start) orelse continue;
            const head = ring[sampleSlot(start)] orelse continue;
            if (!head.state.t.eql(start)) continue;
            var states: [samples_len]fitting.Sample = undefined;
            var n: usize = 0;
            var times: tracking.Cursor = .init(.gps, start, flight_plan.leap);
            while (times.next(end)) |t| {
                const s = ring[sampleSlot(t)] orelse break;
                if (!s.state.t.eql(t) or !s.binding_start.eql(head.binding_start)) break;
                states[n] = s.state;
                n += 1;
            }
            const corr = fitting.correction(head.lnav, epoch, states[0..n]) orelse continue;
            out[i] = .{ .correction = corr, .binding_start = binding_start };
        }
        return out;
    }
};
