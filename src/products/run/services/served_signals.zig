const std = @import("std");
const gnss_types = @import("domain/gnss_types");

const Payload = @import("domain/signals/payload").Payload;

pub const Served = struct {
    signals: std.EnumSet(gnss_types.Signal),
    payload: *const Payload,

    pub fn lists(self: Served, signal: gnss_types.Signal) bool {
        return self.signals.contains(signal);
    }

    pub fn transmits(self: Served, sat: gnss_types.SatId, signal: gnss_types.Signal) bool {
        return self.lists(signal) and self.payload.transmits(sat, signal);
    }

    pub fn listsAny(self: Served, comptime T: type, table: []const T) bool {
        for (table) |row| if (self.lists(row.signal)) return true;
        return false;
    }

    pub fn transmitsAny(self: Served, comptime T: type, table: []const T, sat: gnss_types.SatId) bool {
        for (table) |row| if (self.transmits(sat, row.signal)) return true;
        return false;
    }
};
