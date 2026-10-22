const ionosphere = @import("domain/messages/bds/fields/ionosphere");
const content = @import("domain/messages/bds/bcnav/content");
const records = @import("domain/navigation/records");
const almanac = @import("domain/messages/bds/fields/almanac");
const time = @import("domain/messages/bds/fields/time");
const epoch = @import("domain/messages/fields/almanac_reference");
const GpsTime = @import("domain/time/gps").GpsTime;
const SatSet = @import("domain/gnss_types").SatSet;

pub const Almanacs = struct {
    entries: [63]?almanac.Slot = @splat(null),
    reference: epoch.Reference,

    pub fn init(records_in: []const records.KeplerAlmanac, selected: SatSet, at: GpsTime) Almanacs {
        var out: Almanacs = .{ .reference = .fromTime(at, .bds) };
        for (records_in) |*a| if (selected.contains(a.sat)) {
            out.entries[a.sat.index] = .init(a);
        };
        return out;
    }

    pub fn packet(self: *const Almanacs, prn: u7) almanac.Packet {
        return .{ .slot = if (prn == 0) null else self.entries[prn - 1], .reference = self.reference };
    }
};

pub const System = struct {
    bdgim: ionosphere.Codes,
    utc: ?time.UtcCodes,
    eop: ?time.EopCodes,
    offsets: [3]?time.BgtoCodes,

    pub fn bgto(self: *const System, start: u2) time.BgtoCodes {
        for (0..3) |i| if (self.offsets[(start + i) % 3]) |offset| return offset;
        return time.empty_bgto;
    }
};

pub const Set = struct {
    sv: [63]?*const content.Sv,
    almanacs: *const Almanacs,
    system: *const System,

    pub const Inputs = struct { eph: [63]?*const content.Content, almanacs: *const Almanacs, system: *const System };

    pub fn init(input: Inputs) Set {
        var out: Set = .{ .sv = @splat(null), .almanacs = input.almanacs, .system = input.system };
        for (input.eph, &out.sv) |entry, *slot| slot.* = if (entry) |c| c.value() else null;
        return out;
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.sv[prn - 1] != null;
    }
};
