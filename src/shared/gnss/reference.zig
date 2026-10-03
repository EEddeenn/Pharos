const std = @import("std");
const types = @import("../core.zig").types;
const records = @import("records.zig");
const spec = @import("spec.zig");

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

    pub fn serves(self: Kepler, signal: types.Signal) bool {
        if (signal.system() != self.record.sat.system or self.delay(signal, .data) == null) return false;
        return self.attributesFor(signal).servesSignal(signal);
    }

    pub fn attributesFor(self: Kepler, signal: types.Signal) records.SourceExtra {
        const family = spec.get(signal).family;
        inline for (std.meta.tags(records.NavSource)) |source| {
            if (family == source.family()) {
                if (self.attribute(source)) |attributes| return attributes;
            }
        }
        return self.record.extra;
    }
};
