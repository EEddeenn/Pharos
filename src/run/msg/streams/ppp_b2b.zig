const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const common = @import("common.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const ppp = gnss.bds.ppp_b2b;
const bcnav3 = gnss.bds.bcnav3;
const Kepler = gnss.reference.Kepler;
const corrections = @import("corrections.zig");
const inputs = @import("shared").stage.messages.inputs;

const clock_validity_s = 12;
const orbit_validity_s = 96;

const max_sats = 63 + 37 + 37;
const ring_len = 64;
const max_clock = (max_sats + ppp.clock_entries - 1) / ppp.clock_entries;
const max_modes = @max(ppp.bds_modes.len, ppp.gps_modes.len, ppp.galileo_modes.len);
const ura: ppp.Ura = .{ .class = 0, .value = 0 };
const Corrected = enum { bds, gps, gal };
const System = struct { system: types.System, slot_base: u9, family: types.NavFamily, modes: []const ppp.Mode };
const systems: std.EnumArray(Corrected, System) = .init(.{
    .bds = .{ .system = .bds, .slot_base = ppp.bds_slot_base, .family = .bcnav1, .modes = &ppp.bds_modes },
    .gps = .{ .system = .gps, .slot_base = ppp.gps_slot_base, .family = .lnav, .modes = &ppp.gps_modes },
    .gal = .{ .system = .gal, .slot_base = ppp.galileo_slot_base, .family = .inav, .modes = &ppp.galileo_modes },
});
const Reference = struct { parameters: gnss.kepler_parameters.Parameters, iodn: u10 };
const CorrectedState = struct { value: corrections.Correction, iodn: u10 };

const Entry = struct {
    slot: u9,
    sat: types.SatId,
    corrected: Corrected,
    record: ?Kepler = null,
    broadcast: ?Reference = null,
    iod_corr: u3 = 0,
    orbit_epoch: ?i64 = null,

    fn follow(self: *Entry, record: Kepler) void {
        if (self.record) |previous| {
            if (std.meta.eql(previous, record)) return;
            self.iod_corr +%= 1;
        }
        self.record = record;
        self.broadcast = switch (self.corrected) {
            .bds => if (gnss.bds.bcnav.broadcast(record, .bcnav1)) |b| .{ .parameters = b.parameters, .iodn = @intCast(b.iodc & 0x3ff) } else null,
            .gps => blk: {
                const described = gnss.gps.lnav.described(record);
                break :blk .{ .parameters = described.parameters(), .iodn = @intCast(described.iodc & 0x3ff) };
            },
            .gal => blk: {
                const described = gnss.galileo.inav.described(record);
                break :blk .{ .parameters = described.parameters(), .iodn = described.extra.inav.iod_nav };
            },
        };
        self.orbit_epoch = null;
    }
};
const Slot = struct { message: ppp.Message, available: bool };
const ClockPage = struct { message: ppp.Message, valid_until: i64 };

const Scratch = struct {
    entries: [max_sats]Entry,
    clocks: [max_sats]ppp.ClockEntry,
    biases: [max_sats][max_modes]ppp.Bias,
};

pub const Stream = struct {
    config: bundle.scenario.PppB2b,
    source: common.Source,
    served: common.Served,
    corrected: std.EnumSet(Corrected),
    iodp: u4 = 0,
    entries: [max_sats]Entry = undefined,
    n_entries: usize = 0,
    slots: [ppp.mask_slots]bool = @splat(false),
    cycle_epoch: i64 = 0,
    mask_pending: bool = false,
    orbit_next: usize = 0,
    dcb_next: usize = 0,
    clock_msgs: [max_clock]ClockPage = undefined,
    n_clock: usize = 0,
    clock_next: usize = 0,
    clock_epoch: i64 = 0,
    clock_burst: u2 = 0,
    ring: common.Ring(Slot, ring_len) = .{},
    cadence: common.Cadence,
    scratch: Scratch = undefined,

    pub fn init(self: *Stream, b: *const bundle.Bundle, allocation: *const gnss.allocation.Allocation, config: bundle.scenario.PppB2b) void {
        const served: common.Served = .init(b, allocation);
        var corrected: std.EnumSet(Corrected) = .initOne(.bds);
        if (served.listsAny(ppp.Mode, &ppp.gps_modes)) corrected.insert(.gps);
        if (served.listsAny(ppp.Mode, &ppp.galileo_modes)) corrected.insert(.gal);
        self.* = .{
            .config = config,
            .source = .{ .b = b, .scale = .bds },
            .served = served,
            .corrected = corrected,
            .cadence = .init(core.time.bds_offset_ms, b.scenario.start),
        };
    }

    pub fn reset(self: *Stream) void {
        const config = self.config;
        self.init(self.source.b, self.served.allocation, config);
    }

    pub fn advanceTo(self: *Stream, end: GpsTime) void {
        while (self.cadence.next(end)) |s| {
            const first = s == self.cadence.first;
            const t = self.cadence.timeOf(s);
            if (first or (s - self.cycle_epoch >= self.config.orbit_interval_s and self.orbit_next == self.n_entries)) {
                self.startCycle(s, t);
            }
            if (s - self.clock_epoch >= clock_validity_s) self.clock_next = self.n_clock;
            if (first or (self.clock_next == self.n_clock and s - self.clock_epoch >= self.config.clock_interval_s)) {
                self.clockEpoch(s, t);
            }
            const message = self.nextMessage(s, t);
            self.ring.put(s, .{ .message = message, .available = self.n_entries > 0 });
        }
    }

    fn commonOf(s: i64) ppp.Common {
        return .{ .epoch_s = @intCast(@mod(s, core.time.s_per_day)), .iod_ssr = 0 };
    }

    fn correction(self: *Stream, e: *Entry, t: GpsTime) ?CorrectedState {
        const record = inputs.recordOf(self.source.b, self.served.allocation, systems.get(e.corrected).family, e.sat, self.source.notBefore(t)) orelse return null;
        e.follow(record);
        const reference = if (e.broadcast) |*r| r else return null;
        const value = self.source.correctionAgainst(e.sat, record, &reference.parameters, t, .icd_periodic) orelse return null;
        return .{ .value = value, .iodn = reference.iodn };
    }

    fn orbitCorrection(c: corrections.Correction) ?ppp.OrbitCorrection {
        const rac = c.radialAlongCross();
        return ppp.orbitCorrection(rac[0], rac[1], rac[2]);
    }

    fn startCycle(self: *Stream, s: i64, t: GpsTime) void {
        const entries = &self.scratch.entries;
        var slots: [ppp.mask_slots]bool = @splat(false);
        var n: usize = 0;
        var it = self.corrected.iterator();
        while (it.next()) |corrected| {
            const sys = systems.get(corrected);
            var sats = sys.system.satellites();
            while (sats.next()) |sat| {
                if (!self.served.transmitsAny(ppp.Mode, sys.modes, sat)) continue;
                const slot = sys.slot_base + sat.prn();
                var entry: Entry = .{ .slot = slot, .sat = sat, .corrected = corrected };
                for (self.entries[0..self.n_entries]) |old| if (old.slot == slot) {
                    entry = old;
                    break;
                };
                const c = self.correction(&entry, t) orelse continue;
                if (orbitCorrection(c.value) == null) continue;
                entries[n] = entry;
                slots[slot - 1] = true;
                n += 1;
            }
        }
        if (!std.mem.eql(bool, &slots, &self.slots)) self.iodp +%= 1;
        @memcpy(self.entries[0..n], entries[0..n]);
        self.n_entries = n;
        self.slots = slots;
        self.cycle_epoch = s;
        self.mask_pending = true;
        self.orbit_next = 0;
        if (self.dcb_next >= n) self.dcb_next = 0;
        self.clock_next = self.n_clock;
    }

    fn nextMessage(self: *Stream, s: i64, t: GpsTime) ppp.Message {
        if (self.mask_pending) {
            self.mask_pending = false;
            self.clock_burst = 0;
            return ppp.encode(.{ .mask = .{ .common = commonOf(s), .iodp = self.iodp, .slots = self.slots } }) catch unreachable;
        }
        if (self.orbit_next < self.n_entries and (self.clock_burst >= 2 or self.clock_next == self.n_clock)) {
            self.clock_burst = 0;
            return self.orbitMessage(s, t);
        }
        if (self.clock_next < self.n_clock) {
            const message = self.clock_msgs[self.clock_next];
            self.clock_next += 1;
            self.clock_burst +|= 1;
            return if (s < message.valid_until) message.message else ppp.null_message;
        }
        if (self.dcb_next < self.n_entries) return self.dcbMessage(s, t);
        return ppp.null_message;
    }

    fn dcbMessage(self: *Stream, s: i64, t: GpsTime) ppp.Message {
        const biases = &self.scratch.biases;
        var page: ppp.DcbPage = .{ .common = commonOf(s) };
        while (self.dcb_next < self.n_entries) : (self.dcb_next += 1) {
            const e = &self.entries[self.dcb_next];
            const c = self.correction(e, t) orelse continue;
            var k: usize = 0;
            for (systems.get(e.corrected).modes) |m| if (self.served.transmits(e.sat, m.signal) and c.value.delays.air[gnss.spec.slot(m.signal)].status == .on_air) {
                const code = ppp.dcbCode(core.constants.light_speed * c.value.delays.term(m.signal, m.component)) orelse continue;
                biases[page.count()][k] = .{ .mode = m.mode, .code = code };
                k += 1;
            };
            if (k == 0) continue;
            if (!page.append(.{ .slot = e.slot, .biases = biases[page.count()][0..k] })) break;
        }
        if (page.count() == 0) return ppp.null_message;
        return ppp.encode(.{ .dcb = page }) catch unreachable;
    }

    fn orbitMessage(self: *Stream, s: i64, t: GpsTime) ppp.Message {
        var batch: [ppp.orbit_entries]ppp.OrbitEntry = @splat(ppp.empty_orbit);
        var n: usize = 0;
        const end = @min(self.orbit_next + ppp.orbit_entries, self.n_entries);
        for (self.entries[self.orbit_next..end]) |*e| {
            e.orbit_epoch = null;
            const c = self.correction(e, t) orelse continue;
            const orbit = orbitCorrection(c.value) orelse continue;
            batch[n] = .{ .slot = e.slot, .iodn = c.iodn, .iod_corr = e.iod_corr, .correction = orbit, .ura = ura };
            e.orbit_epoch = s;
            n += 1;
        }
        self.orbit_next = end;
        if (n == 0) return ppp.null_message;
        return ppp.encode(.{ .orbit = .{ .common = commonOf(s), .entries = &batch } }) catch unreachable;
    }

    fn clockEpoch(self: *Stream, s: i64, t: GpsTime) void {
        self.clock_epoch = s;
        const clocks = &self.scratch.clocks;
        for (self.entries[0..self.n_entries], 0..) |*e, i| {
            var code: ?i15 = null;
            if (self.correction(e, t)) |c| {
                if (e.orbit_epoch) |epoch| {
                    if (s - epoch < orbit_validity_s) code = ppp.clockCode(-c.value.clock_delta_m);
                }
            } else e.orbit_epoch = null;
            clocks[i] = .{ .iod_corr = e.iod_corr, .c0 = code };
        }
        self.n_clock = 0;
        self.clock_next = 0;
        var start: usize = 0;
        while (start < self.n_entries) : (start += ppp.clock_entries) {
            const page = clocks[start..@min(start + ppp.clock_entries, self.n_entries)];
            const content: ppp.Content = if (page.len == ppp.clock_entries)
                .{ .clock = .{ .common = commonOf(s), .iodp = self.iodp, .subtype = @intCast(start / ppp.clock_entries), .entries = page[0..ppp.clock_entries] } }
            else
                .{ .combination_mask = .{ .clock = .{ .common = commonOf(s), .iodp = self.iodp, .slot_s = @intCast(start + 1), .entries = page }, .orbit = null } };
            self.clock_msgs[self.n_clock] = .{ .message = ppp.encode(content) catch unreachable, .valid_until = self.clockDeadline(s, start, page) };
            self.n_clock += 1;
        }
    }

    fn clockDeadline(self: *const Stream, s: i64, start: usize, clocks: []const ppp.ClockEntry) i64 {
        var until = s + clock_validity_s;
        for (clocks, self.entries[start..][0..clocks.len]) |clock, e| if (clock.c0 != null) if (e.orbit_epoch) |epoch| {
            until = @min(until, epoch + orbit_validity_s);
        };
        return until;
    }

    pub fn frame(self: *const Stream, prn: u8, s: i64) ?bcnav3.Frame {
        const slot = self.ring.get(s) orelse return null;
        return bcnav3.encodePppFrame(&slot.message, prn, slot.available);
    }
};
