const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");
const accuracy = @import("domain/navigation/accuracy/gps");
const galileo_records = @import("domain/navigation/records/galileo");
const bds_records = @import("domain/navigation/records/bds");
const group_delay = @import("domain/navigation/group_delay");

pub const Reference = union(enum) {
    kepler: Kepler,
    glonass: struct { record: *const records.GlonassEphemeris, group_delay: *const records.GroupDelays },
};

/// The selected attributes and the source record that supplies them, kept together on each leg.
pub const Attributes = struct {
    lnav: ?Sourced(@FieldType(records.SourceExtra, "lnav")) = null,
    cnav: ?Sourced(@FieldType(records.SourceExtra, "cnav")) = null,
    cnav2: ?Sourced(@FieldType(records.SourceExtra, "cnav2")) = null,
    d1d2: ?Sourced(@FieldType(records.SourceExtra, "d1d2")) = null,
    bcnav1: ?Sourced(@FieldType(records.SourceExtra, "bcnav1")) = null,
    bcnav2: ?Sourced(@FieldType(records.SourceExtra, "bcnav2")) = null,
    bcnav3: ?Sourced(@FieldType(records.SourceExtra, "bcnav3")) = null,
    inav: ?Sourced(@FieldType(records.SourceExtra, "inav")) = null,
    fnav: ?Sourced(@FieldType(records.SourceExtra, "fnav")) = null,

    pub fn get(self: *const Attributes, source: records.NavSource) ?Sourced(records.SourceExtra) {
        return switch (source) {
            inline else => |tag| if (@field(self, @tagName(tag))) |entry|
                .{ .value = @unionInit(records.SourceExtra, @tagName(tag), entry.value), .record = entry.record }
            else
                null,
        };
    }

    pub fn put(self: *Attributes, value: records.SourceExtra, record: u32) void {
        switch (value) {
            inline else => |payload, tag| @field(self, @tagName(tag)) = .{ .value = payload, .record = record },
        }
    }

    pub fn sources(self: *const Attributes) std.EnumMap(records.NavSource, u32) {
        var out: std.EnumMap(records.NavSource, u32) = .{};
        inline for (std.enums.values(records.NavSource)) |source| {
            if (@field(self, @tagName(source))) |entry| out.put(source, entry.record);
        }
        return out;
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
        if (self.attributes) |attributes| if (attributes.get(source)) |entry| return entry.value;
        return if (self.record.source() == source) self.record.extra else null;
    }

    pub fn delay(self: Kepler, signal: gnss_types.Signal, component: gnss_types.Component) ?f64 {
        return group_delay.forGroupDelays(self.group_delay, self.record.source(), signal, component);
    }

    /// The source whose declaration gives a signal's health on the leg: the first in the signal's order that states the
    /// signal's condition; the record of the family carrying the signal ends the search even where it states nothing.
    pub fn declaration(self: Kepler, signal: gnss_types.Signal, carrier: ?gnss_types.NavFamily) ?records.NavSource {
        for (healthOrder(signal)) |source| {
            const extra = self.attribute(source) orelse continue;
            if (source.family() == carrier or extra.signalStatus(signal) != .unstated) return source;
        }
        return null;
    }
};

/// The attributes a family carries for the reference `e` from `donor`, the family's latest record: `e`'s own where the
/// family is `e`'s; else `donor`'s, with the accuracy and the issue made to fit `e` where the two records differ.
pub fn attributesOf(e: *const records.KeplerEphemeris, donor: *const records.KeplerEphemeris) records.SourceExtra {
    if (donor.source() == e.source()) return donor.extra;
    const same = std.meta.eql(e.parameters(), donor.parameters());
    var out = donor.extra;
    switch (out) {
        .lnav => |*x| x.ura_index = if (same) x.ura_index else 15,
        .cnav => |*x| x.ura = gpsUra(e),
        .cnav2 => |*x| x.ura = gpsUra(e),
        inline .inav, .fnav => |*x| {
            const issue = galileoIssue(e);
            if (!e.toe.eql(donor.toe) or x.iod_nav != issue) x.sisa_index = galileo_records.sisa_napa;
            x.iod_nav = issue;
        },
        .d1d2 => |*x| x.ura_index = if (same) x.ura_index else 15,
        .bcnav1, .bcnav2, .bcnav3 => |*x| {
            x.sat_type = switch (e.extra) {
                .bcnav1, .bcnav2, .bcnav3 => |own| own.sat_type,
                else => bds_records.satTypeOf(e.sat.prn(), e.sqrt_a),
            };
            switch (e.extra) {
                .bcnav1, .bcnav2, .bcnav3 => |own| {
                    x.sismai = own.sismai;
                    x.sisai_oe = own.sisai_oe;
                    x.sisai_ocb = own.sisai_ocb;
                    x.sisai_oc1 = own.sisai_oc1;
                    x.sisai_oc2 = own.sisai_oc2;
                },
                else => if (!same) {
                    x.sismai = 15;
                    x.sisai_oe = 31;
                    x.sisai_ocb = 31;
                    x.sisai_oc1 = 7;
                    x.sisai_oc2 = 7;
                    if (x.b1c) |*flags| flags.aif = true;
                    if (x.b2a) |*flags| flags.aif = true;
                    if (x.b2b) |*flags| flags.aif = true;
                },
            }
        },
    }
    return out;
}

pub fn galileoIssue(e: *const records.KeplerEphemeris) u10 {
    return switch (e.extra) {
        .inav => |x| x.iod_nav,
        .fnav => |x| x.iod_nav,
        else => @truncate(e.iode),
    };
}

fn Sourced(comptime Value: type) type {
    return struct { value: Value, record: u32 };
}

/// The families that declare a signal's health, in the order they are read: the signal's own first (IS-GPS-200N
/// 6.4.6.1, SPS PS 2.3.2, BDS-OS-PS 3.0 5.3.3.2), but B-CNAV2's SIF(B1C) before B-CNAV1, as BDS-OS-PS 3.0 recommends.
fn healthOrder(signal: gnss_types.Signal) []const records.NavSource {
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

fn gpsUra(e: *const records.KeplerEphemeris) accuracy.Ura {
    return switch (e.extra) {
        .lnav => |x| accuracy.ofLnav(x.ura_index),
        .cnav => |x| x.ura,
        .cnav2 => |x| x.ura,
        else => .{ .ed = 15, .ned0 = 15, .ned1 = 7, .ned2 = 7 },
    };
}
