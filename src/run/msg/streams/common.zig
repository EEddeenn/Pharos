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

    // A frame the run starts inside of is made from the state at the start: nothing is known before it.
    pub fn notBefore(self: *const Source, t: GpsTime) GpsTime {
        return if (t.lessThan(self.b.plan.start)) self.b.plan.start else t;
    }

    pub fn correctionOf(self: *Source, sat: types.SatId, t: GpsTime, relativity: corrections.Relativity) ?corrections.Correction {
        const at = self.notBefore(t);
        return corrections.compute(self.trackAt(sat, at), at, relativity, self.b.plan.scaleOffset(self.scale, at));
    }

    pub fn correctionAgainst(self: *Source, sat: types.SatId, record: gnss.reference.Kepler, reference: *const gnss.kepler_parameters.Parameters, t: GpsTime, relativity: corrections.Relativity) ?corrections.Correction {
        const at = self.notBefore(t);
        return corrections.against(self.trackAt(sat, at), record, reference, at, relativity, self.b.plan.scaleOffset(self.scale, at));
    }

    fn trackAt(self: *Source, sat: types.SatId, t: GpsTime) *track.provider.Track {
        const slot = &self.satellites[sat.key()];
        _ = slot.advanceTo(self.b, sat, t);
        return slot;
    }
};

pub const Served = struct {
    signals: std.EnumSet(types.Signal),
    payload: *const gnss.payload.Payload,

    pub fn init(b: *const bundle.Bundle, payload: *const gnss.payload.Payload) Served {
        return .{ .signals = b.scenario.signals, .payload = payload };
    }

    pub fn lists(self: Served, signal: types.Signal) bool {
        return self.signals.contains(signal);
    }

    pub fn transmits(self: Served, sat: types.SatId, signal: types.Signal) bool {
        return self.lists(signal) and self.payload.transmits(sat, signal);
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
    first: i64,
    served_through: i64,

    pub fn init(offset_ms: i64, start: GpsTime) Cadence {
        const first = @divFloor(start.ms - offset_ms, 1000);
        return .{ .offset_ms = offset_ms, .first = first, .served_through = first - 1 };
    }

    pub fn next(self: *Cadence, t: GpsTime) ?i64 {
        if (self.served_through >= @divFloor(t.ms - self.offset_ms, 1000)) return null;
        self.served_through += 1;
        return self.served_through;
    }

    pub fn timeOf(self: Cadence, second: i64) GpsTime {
        return .{ .ms = second * 1000 + self.offset_ms };
    }
};
