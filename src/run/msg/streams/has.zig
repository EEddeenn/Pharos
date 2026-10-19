const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const common = @import("common.zig");
const types = core.types;
const GpsTime = core.time.GpsTime;
const has = gnss.galileo.has;
const cnav_has = gnss.galileo.cnav;
const corrections = @import("corrections.zig");

const definition_hold_s = 1800;
const mid_reuse_guard_s = 150;

const orbit_validity: has.Validity = .s300;
const clock_validity: has.Validity = .s30;
const bias_validity: has.Validity = .s300;

const System = struct {
    gnss: has.Gnss,
    system: types.System,
    family: types.NavFamily,
    cells: []const has.Cell,
};

const system_table = [_]System{
    .{ .gnss = .gps, .system = .gps, .family = .lnav, .cells = &has.gps_cells },
    .{ .gnss = .galileo, .system = .gal, .family = .inav, .cells = &has.galileo_cells },
};

const carriers = types.System.gal.capacity();
const max_systems = system_table.len;
const max_sats = types.System.gps.capacity() + types.System.gal.capacity();
const history_per_kind = 4;
const max_signals: usize = @max(has.gps_cells.len, has.galileo_cells.len);
const max_cells = max_systems * has.sat_mask_bits * max_signals;

const Kind = enum { slow, fast, bias };

const lifetime_s: std.EnumArray(Kind, u32) = .init(.{
    .slow = orbit_validity.seconds().?,
    .fast = clock_validity.seconds().?,
    .bias = bias_validity.seconds().?,
});

const PhaseState = struct { whole: f64, pdi: u2 };

const Record = struct {
    epoch_s: i64,
    until_s: i64,
    mask_id: u5,
    iod_set_id: u5,
    mid: u5,
    size: u6,
    pages: [has.encoded_pages]has.Page,
};

const Snapshot = struct {
    count: usize = 0,
    corr: [max_sats]corrections.Correction = undefined,
    issues: [max_sats]u16 = undefined,
    masks: [max_systems]has.SystemMask = undefined,
    iods: [max_systems][has.sat_mask_bits]?u16 = @splat(@splat(null)),
    n_systems: usize = 0,
    cells: [max_systems][has.sat_mask_bits * max_signals]bool = undefined,
};

const Scratch = struct {
    snapshot: Snapshot,
    orbit: [max_sats]has.Orbit,
    clocks: [max_sats]has.Clock,
    code: [max_cells]?f64,
    phase: [max_cells]?has.PhaseBias,
    bits: has.MessageBits,
    pages: [has.max_pages]has.Page,
};

// The issue a correction refers to, as the satellite broadcasts it: LNAV's IODE, or I/NAV's IODnav of 10 bits.
fn issueOf(eph: *const gnss.records.KeplerEphemeris) u16 {
    return switch (eph.extra) {
        .inav => |x| x.iod_nav,
        else => eph.iode,
    };
}

pub const Stream = struct {
    config: bundle.scenario.Has,
    status: has.Status,
    source: common.Source,
    served: common.Served,
    systems: []const System,
    messages: std.EnumArray(Kind, [history_per_kind]?Record) = .initFill(@splat(null)),
    next_mid: u5 = 0,
    mid_until: [32]?i64 = @splat(null),
    definitions: [32][32]?i64 = @splat(@splat(null)),
    mask_id: u5 = 0,
    iod_set_id: u5 = 0,
    last_iods: [max_systems][has.sat_mask_bits]?u16 = @splat(@splat(null)),
    phase: [max_systems][has.sat_mask_bits][has.sig_mask_bits]?PhaseState = @splat(@splat(@splat(null))),
    cadence: common.Cadence,
    started: bool = false,
    scratch: Scratch = undefined,

    pub fn init(self: *Stream, b: *const bundle.Bundle, payload: *const gnss.payload.Payload, config: bundle.scenario.Has) void {
        const served: common.Served = .init(b, payload);
        const status: has.Status = switch (config.status) {
            .test_mode => .test_mode,
            .operational => .operational,
        };
        // HAS corrects GPS against LNAV, which only L1 C/A carries.
        const systems: []const System = if (served.lists(.l1ca)) &system_table else system_table[1..];
        self.* = .{
            .config = config,
            .status = status,
            .source = .{ .b = b, .scale = .gal },
            .served = served,
            .systems = systems,
            .cadence = .init(0, b.scenario.start),
        };
    }

    pub fn reset(self: *Stream) void {
        const config = self.config;
        self.init(self.source.b, self.served.payload, config);
    }

    pub fn advanceTo(self: *Stream, t: GpsTime) void {
        while (self.cadence.next(t)) |s| {
            const slow_due = !self.started or common.due(s, self.config.orbit_interval_s);
            const fast_due = !self.started or common.due(s, self.config.clock_interval_s);
            if (slow_due or fast_due) self.generate(s, slow_due, fast_due);
        }
    }

    fn snapshot(self: *Stream, t: GpsTime) *const Snapshot {
        const snap = &self.scratch.snapshot;
        snap.* = .{};
        for (self.systems) |sys| {
            var mask: has.SystemMask = .{ .gnss = sys.gnss, .sats = @splat(false), .sigs = @splat(false), .cells = null, .nav_message = 0 };
            for (sys.cells) |c| if (self.served.lists(c.signal)) {
                mask.sigs[c.index] = true;
            };
            var cells: usize = 0;
            var every = true;
            var sats = sys.system.satellites();
            while (sats.next()) |sat| {
                if (!self.served.transmitsAny(has.Cell, sys.cells, sat)) continue;
                const content = self.source.contentAt(sat, sys.family, t) orelse continue;
                const eph = switch (content.*) {
                    inline .lnav, .inav => |*c| c.value(),
                    else => unreachable,
                } orelse continue;
                const sample = self.source.correctionAgainst(sat, &eph.parameters(), t, .dot_product) orelse continue;
                const prn = sat.prn();
                snap.corr[snap.count] = sample;
                snap.issues[snap.count] = issueOf(eph);
                snap.count += 1;
                mask.sats[prn - 1] = true;
                snap.iods[snap.n_systems][prn - 1] = issueOf(eph);
                for (sys.cells) |c| if (mask.sigs[c.index]) {
                    const on = self.served.transmits(sat, c.signal);
                    snap.cells[snap.n_systems][cells] = on;
                    cells += 1;
                    every = every and on;
                };
            }
            if (!every) mask.cells = snap.cells[snap.n_systems][0..cells];
            snap.masks[snap.n_systems] = mask;
            snap.n_systems += 1;
        }
        return snap;
    }

    fn generate(self: *Stream, s: i64, slow_due: bool, fast_due: bool) void {
        const snap = self.snapshot(self.cadence.timeOf(s));
        if (snap.count == 0) {
            for (std.enums.values(Kind)) |kind| self.retire(s, kind);
            return;
        }
        const mask: has.Mask = .{ .systems = snap.masks[0..snap.n_systems] };
        var mask_changed = false;
        var iods_changed = false;
        for (0..max_systems) |k| for (0..has.sat_mask_bits) |i| {
            const now = snap.iods[k][i];
            const before = self.last_iods[k][i];
            if ((now == null) != (before == null)) mask_changed = true;
            if (now != null and before != null and now != before) iods_changed = true;
        };
        const changed = mask_changed or iods_changed;
        const toh: u12 = @intCast(@mod(s, core.time.s_per_hour));
        var redefined = false;
        if (slow_due or changed) define: {
            const mask_id = self.mask_id +% @intFromBool(self.started and mask_changed);
            const iod_set_id = self.iod_set_id +% @intFromBool(self.started and changed);
            if (changed) if (self.definitions[mask_id][iod_set_id]) |until| {
                if (s < until + definition_hold_s) break :define;
            };
            if (!self.slowMessage(s, toh, mask, snap, mask_id, iod_set_id)) break :define;
            self.definitions[mask_id][iod_set_id] = s + lifetime_s.get(.slow);
            self.mask_id = mask_id;
            self.iod_set_id = iod_set_id;
            self.last_iods = snap.iods;
            self.biasMessage(s, toh, mask, snap);
            redefined = changed;
        }
        if (self.current(.slow, s) == null) return;
        if (fast_due or redefined) self.fastMessage(s, toh, snap);
    }

    fn slowMessage(self: *Stream, s: i64, toh: u12, mask: has.Mask, snap: *const Snapshot, mask_id: u5, iod_set_id: u5) bool {
        const orbit = &self.scratch.orbit;
        for (snap.corr[0..snap.count], snap.issues[0..snap.count], 0..) |c, issue, i| {
            const ntw = c.ntw();
            orbit[i] = .{ .iod = issue, .radial_m = ntw[0], .in_track_m = ntw[1], .cross_m = ntw[2] };
        }
        const message: has.Message = .{
            .toh = toh,
            .mask_id = mask_id,
            .iod_set_id = iod_set_id,
            .mask = mask,
            .orbit = .{ .validity = orbit_validity, .sats = orbit[0..snap.count] },
        };
        return self.push(.slow, s, &message, null);
    }

    fn fastMessage(self: *Stream, s: i64, toh: u12, snap: *const Snapshot) void {
        var systems: [max_systems]has.SystemMask = undefined;
        var multipliers: [max_systems]u2 = undefined;
        const clocks = &self.scratch.clocks;
        var n: usize = 0;
        var i: usize = 0;
        for (self.last_iods[0..snap.n_systems], 0..) |iods, k| {
            const first = n;
            var sats: [has.sat_mask_bits]bool = @splat(false);
            for (iods, snap.iods[k], 0..) |linked, now, p| {
                var clock_m: ?f64 = null;
                if (now) |iod| {
                    if (linked == iod) clock_m = snap.corr[i].clock_delta_m;
                    i += 1;
                }
                if (linked == null) continue;
                sats[p] = true;
                clocks[n] = if (clock_m) |v| .{ .value_m = v } else .not_available;
                n += 1;
            }
            var m: u2 = 0;
            while (m < 3 and !carries(clocks[first..n], m)) m += 1;
            multipliers[k] = m;
            systems[k] = .{ .gnss = snap.masks[k].gnss, .sats = sats, .sigs = @splat(false), .cells = null, .nav_message = 0 };
        }
        const mask: has.Mask = .{ .systems = systems[0..snap.n_systems] };
        const message: has.Message = .{
            .toh = toh,
            .mask_id = self.mask_id,
            .iod_set_id = self.iod_set_id,
            .clock_full = .{ .validity = clock_validity, .multipliers = multipliers[0..mask.systems.len], .sats = clocks[0..n] },
        };
        _ = self.push(.fast, s, &message, mask);
    }

    fn biasMessage(self: *Stream, s: i64, toh: u12, mask: has.Mask, snap: *const Snapshot) void {
        const code = &self.scratch.code;
        const phase = &self.scratch.phase;
        var n: usize = 0;
        var i: usize = 0;
        for (mask.systems, 0..) |sys, k| {
            for (snap.corr[i .. i + sys.satCount()]) |c| {
                for (self.systems[k].cells) |cell| if (sys.sigs[cell.index] and self.served.transmits(c.sat, cell.signal)) {
                    if (c.delays.air[gnss.spec.slot(cell.signal)].status != .on_air) {
                        code[n] = null;
                        phase[n] = null;
                        n += 1;
                        continue;
                    }
                    const code_s = c.delays.term(cell.signal, cell.component);
                    const cycles = -@as(f64, @floatFromInt(gnss.spec.nominalCarrierHz(cell.signal))) * c.delays.carrierTerm(cell.signal);
                    const state = &self.phase[k][c.sat.prn() - 1][cell.index];
                    const kept: PhaseState = if (state.*) |st|
                        (if (@abs(cycles - st.whole) <= has.phase_bias_max) st else .{ .whole = @round(cycles), .pdi = st.pdi +% 1 })
                    else
                        .{ .whole = @round(cycles), .pdi = 0 };
                    state.* = kept;
                    code[n] = -core.constants.light_speed * code_s;
                    phase[n] = .{ .cycles = cycles - kept.whole, .discontinuity = kept.pdi };
                    n += 1;
                };
            }
            i += sys.satCount();
        }
        const message: has.Message = .{
            .toh = toh,
            .mask_id = self.mask_id,
            .iod_set_id = self.iod_set_id,
            .code_bias = .{ .validity = bias_validity, .cells = code[0..n] },
            .phase_bias = .{ .validity = bias_validity, .cells = phase[0..n] },
        };
        _ = self.push(.bias, s, &message, mask);
    }

    fn carries(clocks: []const has.Clock, multiplier: u2) bool {
        for (clocks) |c| switch (c) {
            .value_m => |v| if (!has.clockFits(v, multiplier)) return false,
            else => {},
        };
        return true;
    }

    fn retire(self: *Stream, s: i64, kind: Kind) void {
        for (self.messages.getPtr(kind)) |*entry| {
            const r = if (entry.*) |*record| record else continue;
            if (r.epoch_s <= s and r.until_s > s) {
                r.until_s = s;
                self.mid_until[r.mid] = s + mid_reuse_guard_s;
            }
        }
    }

    fn push(self: *Stream, kind: Kind, s: i64, message: *const has.Message, context: ?has.Mask) bool {
        var mid = self.next_mid;
        for (0..32) |_| {
            const until = self.mid_until[mid] orelse break;
            if (until <= s) break;
            mid +%= 1;
        } else return false;
        const bits = &self.scratch.bits;
        bits.* = .{};
        const written = has.encode(message, context, bits) catch unreachable;
        const pages = &self.scratch.pages;
        const k = has.split(bits, written, pages);
        const kept = self.messages.getPtr(kind);
        var slot: usize = 0;
        var oldest_s: i64 = std.math.maxInt(i64);
        for (kept, 0..) |*entry, idx| {
            const r = if (entry.*) |*record| record else {
                slot = idx;
                break;
            };
            if (r.epoch_s < oldest_s) {
                oldest_s = r.epoch_s;
                slot = idx;
            }
        }
        self.retire(s, kind);
        kept[slot] = .{
            .epoch_s = s,
            .until_s = s + lifetime_s.get(kind),
            .mask_id = message.mask_id,
            .iod_set_id = message.iod_set_id,
            .mid = mid,
            .size = @intCast(k),
            .pages = undefined,
        };
        const record = &kept[slot].?;
        has.encodePages(pages[0..k], &record.pages);
        self.mid_until[mid] = record.until_s + mid_reuse_guard_s;
        self.next_mid = mid +% 1;
        self.started = true;
        return true;
    }

    fn current(self: *const Stream, kind: Kind, s: i64) ?*const Record {
        var best: ?*const Record = null;
        for (self.messages.getPtrConst(kind)) |*m| {
            const r = if (m.*) |*rec| rec else continue;
            if (r.epoch_s > s or s >= r.until_s) continue;
            if (best) |b| if (b.epoch_s >= r.epoch_s) continue;
            best = r;
        }
        return best;
    }

    pub fn frame(self: *const Stream, prn: u8, s: i64) ?cnav_has.Frame {
        const slow = self.current(.slow, s) orelse return null;
        const kind: Kind = switch (@mod(s, 4)) {
            0, 2 => .fast,
            1 => .slow,
            else => .bias,
        };
        var rec = slow;
        if (self.current(kind, s)) |other| {
            if (other.mask_id == slow.mask_id and other.iod_set_id == slow.iod_set_id) rec = other;
        }
        const size: usize = rec.size;
        const age: usize = @intCast(s - rec.epoch_s);
        const q = (carriers * age + prn - 1) % (size + has.parity_pages);
        const pid: u8 = @intCast(if (q < size) q + 1 else has.max_data_pages + 1 + (q - size));
        const header: has.Header = .{ .status = self.status, .message_id = rec.mid, .size = rec.size, .page_id = pid };
        return has.cnavPage(header, &rec.pages[pid - 1]);
    }
};
