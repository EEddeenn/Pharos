const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const track = @import("shared").track;
const bundle = @import("shared").bundle;
const types = core.types;
const GpsTime = core.time.GpsTime;
const corrections = @import("corrections.zig");

pub fn Ring(comptime T: type, comptime len: usize) type {
    return struct {
        const Slot = struct { index: i64, value: T };

        slots: [len]?Slot = @splat(null),

        pub fn put(self: *@This(), index: i64, value: T) void {
            self.slots[@intCast(@mod(index, len))] = .{ .index = index, .value = value };
        }

        pub fn get(self: *const @This(), index: i64) ?T {
            const slot = self.slots[@intCast(@mod(index, len))] orelse return null;
            return if (slot.index == index) slot.value else null;
        }
    };
}

pub const Source = struct {
    b: *const bundle.Bundle,
    scale: types.System,
    satellites: [256]track.provider.Track = @splat(.{}),

    pub fn correctionOf(self: *Source, sat: types.SatId, t: GpsTime, relativity: corrections.Relativity) ?corrections.Correction {
        return corrections.compute(self.trackAt(sat, t), t, relativity, self.b.plan.scaleOffset(self.scale, t));
    }

    pub fn correctionAgainst(self: *Source, sat: types.SatId, record: gnss.reference.Kepler, reference: *const gnss.kepler_parameters.Parameters, t: GpsTime, relativity: corrections.Relativity) ?corrections.Correction {
        return corrections.against(self.trackAt(sat, t), record, reference, t, relativity, self.b.plan.scaleOffset(self.scale, t));
    }

    fn trackAt(self: *Source, sat: types.SatId, t: GpsTime) *track.provider.Track {
        const slot = &self.satellites[sat.key()];
        _ = slot.advanceTo(self.b, sat, t);
        return slot;
    }

    pub fn collect(self: *Source, system: types.System, t: GpsTime, relativity: corrections.Relativity, out: []corrections.Correction) usize {
        var n: usize = 0;
        var sats = system.satellites();
        while (n < out.len) {
            const sat = sats.next() orelse break;
            const corr = self.correctionOf(sat, t, relativity) orelse continue;
            out[n] = corr;
            n += 1;
        }
        return n;
    }
};

pub const Served = struct {
    signals: std.EnumSet(types.Signal),
    allocation: *const gnss.allocation.Allocation,

    pub fn init(b: *const bundle.Bundle, allocation: *const gnss.allocation.Allocation) Served {
        return .{ .signals = b.scenario.signals, .allocation = allocation };
    }

    pub fn lists(self: Served, signal: types.Signal) bool {
        return self.signals.contains(signal);
    }

    pub fn transmits(self: Served, sat: types.SatId, signal: types.Signal) bool {
        return self.lists(signal) and self.allocation.transmits(sat, signal);
    }

    pub fn listsAny(self: Served, comptime T: type, table: []const T) bool {
        for (table) |row| if (self.lists(row.signal)) return true;
        return false;
    }

    pub fn transmitsAny(self: Served, comptime T: type, table: []const T, sat: types.SatId) bool {
        for (table) |row| if (self.transmits(sat, row.signal)) return true;
        return false;
    }
};

pub fn due(second: i64, interval_s: u32) bool {
    return @mod(second, interval_s) == 0;
}

pub const Cadence = struct {
    offset_ms: i64,
    served_through: i64,
    generated: u32 = 0,

    pub fn init(offset_ms: i64, start: GpsTime) Cadence {
        var c: Cadence = .{ .offset_ms = offset_ms, .served_through = 0 };
        c.served_through = c.secondOf(start) - 1;
        return c;
    }

    pub fn secondOf(self: Cadence, t: GpsTime) i64 {
        return @divFloor(t.ms - self.offset_ms, 1000);
    }

    pub fn isFirst(self: Cadence) bool {
        return self.generated == 0;
    }

    pub fn upTo(self: *Cadence, upto: i64) Walk {
        return .{ .cadence = self, .upto = upto };
    }

    const Walk = struct {
        cadence: *Cadence,
        upto: i64,

        pub fn next(self: Walk) ?i64 {
            const s = self.cadence.served_through + 1;
            if (s > self.upto) return null;
            self.cadence.served_through = s;
            return s;
        }
    };

    pub fn timeOf(self: Cadence, second: i64) GpsTime {
        return .{ .ms = second * 1000 + self.offset_ms };
    }
};
