const types = @import("../core.zig").types;
const records = @import("records.zig");

pub const Attributes = struct {
    lnav: ?@FieldType(records.SourceExtra, "lnav") = null,
    cnav: ?@FieldType(records.SourceExtra, "cnav") = null,
    cnav2: ?@FieldType(records.SourceExtra, "cnav2") = null,
    d1d2: ?@FieldType(records.SourceExtra, "d1d2") = null,
    bcnav1: ?@FieldType(records.SourceExtra, "bcnav1") = null,
    bcnav2: ?@FieldType(records.SourceExtra, "bcnav2") = null,
    bcnav3: ?@FieldType(records.SourceExtra, "bcnav3") = null,
    inav: ?@FieldType(records.SourceExtra, "inav") = null,
    fnav: ?@FieldType(records.SourceExtra, "fnav") = null,

    pub fn get(self: Attributes, source: records.NavSource) ?records.SourceExtra {
        return switch (source) {
            inline else => |tag| if (@field(self, @tagName(tag))) |value| @unionInit(records.SourceExtra, @tagName(tag), value) else null,
        };
    }

    pub fn put(self: *Attributes, value: records.SourceExtra) void {
        switch (value) {
            inline else => |payload, tag| @field(self, @tagName(tag)) = payload,
        }
    }
};

pub const Kepler = struct {
    record: *const records.KeplerEphemeris,
    group_delay: *const records.GroupDelays,
    attributes: ?*const Attributes = null,

    pub fn raw(record: *const records.KeplerEphemeris) Kepler {
        return .{ .record = record, .group_delay = &record.group_delay };
    }

    pub fn attribute(self: Kepler, source: records.NavSource) ?records.SourceExtra {
        if (self.attributes) |attributes| if (attributes.get(source)) |value| return value;
        return if (self.record.source() == source) self.record.extra else null;
    }

    pub fn delay(self: Kepler, signal: types.Signal, component: types.Component) ?f64 {
        return @import("delay.zig").forGroupDelays(self.group_delay, self.record.source(), signal, component);
    }

    /// The record whose declaration gives a signal's health on the leg: the first in the signal's order that states the
    /// signal's condition; the record of the family carrying the signal ends the search even where it states nothing.
    pub fn declaration(self: Kepler, signal: types.Signal, carrier: ?types.NavFamily) ?records.SourceExtra {
        for (healthOrder(signal)) |source| {
            const extra = self.attribute(source) orelse continue;
            if (source.family() == carrier or extra.signalStatus(signal) != .unstated) return extra;
        }
        return null;
    }
};

/// The families that declare a signal's health, in the order they are read: the signal's own first (IS-GPS-200N
/// 6.4.6.1, SPS PS 2.3.2, BDS-OS-PS 3.0 5.3.3.2), but B-CNAV2's SIF(B1C) before B-CNAV1, as BDS-OS-PS 3.0 recommends.
fn healthOrder(signal: types.Signal) []const records.NavSource {
    return switch (signal) {
        .l1ca => &.{ .lnav, .cnav },
        .l1c => &.{ .cnav2, .cnav, .lnav },
        .l2c, .l5 => &.{ .cnav, .lnav },
        .b1i, .b2i, .b3i => &.{.d1d2},
        .b1c => &.{ .bcnav2, .bcnav1, .d1d2 },
        .b2a => &.{ .bcnav2, .d1d2 },
        .b2b => &.{ .bcnav3, .d1d2 },
        .e1, .e5b => &.{.inav},
        .e5a => &.{.fnav},
        .e6, .g1, .g2 => &.{},
    };
}
