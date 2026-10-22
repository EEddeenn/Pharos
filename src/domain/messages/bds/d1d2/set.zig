const klobuchar = @import("domain/messages/fields/klobuchar");
const content = @import("domain/messages/bds/d1d2/content");
const records = @import("domain/navigation/records");
const health = @import("domain/navigation/health");
const time = @import("domain/time/gps");
const epoch = @import("domain/navigation/almanac_epoch");
const pages = @import("domain/messages/bds/d1d2/pages");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const SatSet = @import("domain/gnss_types").SatSet;

pub const Almanacs = struct {
    entries: [63]?*const records.KeplerAlmanac = @splat(null),
    health: [63]u9 = @splat(health.almanac_health_all),
    wna: u8,
    toa: u8,

    pub fn init(records_in: []const records.KeplerAlmanac, selected: SatSet, at: time.GpsTime) Almanacs {
        const bdt = at.inScale(.bds);
        var out: Almanacs = .{ .wna = @intCast(@mod(bdt.period, time.week_modulus_8)), .toa = @intCast(bdt.ms / epoch.toa_step_ms) };
        for (records_in) |*a| if (selected.contains(a.sat)) {
            out.entries[a.sat.index] = a;
            out.health[a.sat.index] = a.health;
        };
        return out;
    }
};

pub const System = struct { utc: pages.UtcPage, klobuchar: klobuchar.Codes, epoch: time.GpsTime };

pub const Set = struct {
    sv: [63]?*const content.Prepared,
    almanacs: *const Almanacs,
    system: ?*const System,
    publications: []const augmentation.PreparedPublication = &.{},
    service: ?augmentation.Source = null,

    pub const Inputs = struct {
        eph: [63]?*const content.Content,
        almanacs: *const Almanacs,
        system: ?*const System,
        publications: []const augmentation.PreparedPublication = &.{},
        service: ?augmentation.Source = null,
    };

    pub fn init(input: Inputs) Set {
        var out: Set = .{ .sv = @splat(null), .almanacs = input.almanacs, .system = input.system, .publications = input.publications, .service = input.service };
        for (input.eph, &out.sv) |entry, *slot| slot.* = if (entry) |c| c.value() else null;
        return out;
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.sv[prn - 1] != null and self.system != null;
    }
};
