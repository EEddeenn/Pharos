const content = @import("domain/messages/glonass/gnav/content");
const glonass_records = @import("domain/navigation/records/glonass");
const gnss_types = @import("domain/gnss_types");
const system = @import("domain/messages/glonass/gnav/system");
const slots = gnss_types.System.glo.capacity();

pub const Almanacs = struct {
    entries: [slots]?*const glonass_records.GlonassAlmanac = @splat(null),

    pub fn init(records_in: []const glonass_records.GlonassAlmanac, selected: gnss_types.SatSet) Almanacs {
        var out: Almanacs = .{};
        for (records_in) |*a| if (selected.contains(a.sat)) {
            out.entries[a.sat.index] = a;
        };
        return out;
    }
};

pub const Set = struct {
    eph: [slots]?*const content.Prepared,
    almanacs: *const Almanacs,
    system: ?*const system.System,

    pub const Inputs = struct { eph: [slots]?*const content.Content, almanacs: *const Almanacs, system: ?*const system.System };

    pub fn init(input: Inputs) Set {
        var out: Set = .{ .eph = @splat(null), .almanacs = input.almanacs, .system = input.system };
        for (input.eph, &out.eph) |entry, *slot| slot.* = if (entry) |c| c.value() else null;
        return out;
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.eph[prn - 1] != null and self.system != null;
    }
};
