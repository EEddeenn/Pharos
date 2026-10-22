const gnss_types = @import("domain/gnss_types");
const records = @import("domain/navigation/records");
const publications = @import("simulation/model/publications");
const systems = @import("simulation/model/systems");
const lnav = @import("domain/messages/gps/lnav/set");
const cnav = @import("domain/messages/gps/cnav_common/set");
const galileo = @import("domain/messages/galileo/fields/almanac");
const d1d2 = @import("domain/messages/bds/d1d2/set");
const bcnav = @import("domain/messages/bds/bcnav/set");
const gnav = @import("domain/messages/glonass/gnav/set");
const gnav_system = @import("domain/messages/glonass/gnav/system");
const GpsTime = @import("domain/time/gps").GpsTime;

pub const AlmanacChoices = struct {
    lnav: gnss_types.SatSet = .empty,
    cnav: gnss_types.SatSet = .empty,
    galileo: gnss_types.SatSet = .empty,
    d1d2: gnss_types.SatSet = .empty,
    bcnav: gnss_types.SatSet = .empty,
    gnav: gnss_types.SatSet = .empty,
};

pub const StoredAlmanacs = struct {
    gps: []const records.KeplerAlmanac = &.{},
    galileo: []const records.KeplerAlmanac = &.{},
    bds: []const records.KeplerAlmanac = &.{},
    glonass: []const records.GlonassAlmanac = &.{},
    gps_epoch: GpsTime,
    galileo_epoch: GpsTime,
    bds_epoch: GpsTime,
    glonass_day: ?gnav_system.Day,
    selected: AlmanacChoices,
};

pub const Almanacs = struct {
    lnav: lnav.Almanacs,
    cnav: cnav.Almanacs,
    galileo: galileo.Almanacs,
    d1d2: d1d2.Almanacs,
    bcnav: bcnav.Almanacs,
    gnav: gnav.Almanacs,

    pub fn init(stored: *const StoredAlmanacs, configuration: *const [63]u3) Almanacs {
        return .{
            .lnav = .init(stored.gps, stored.selected.lnav, stored.gps_epoch, configuration),
            .cnav = .init(stored.gps, stored.selected.cnav, stored.gps_epoch),
            .galileo = .init(stored.galileo, stored.selected.galileo, stored.galileo_epoch),
            .d1d2 = .init(stored.bds, stored.selected.d1d2, stored.bds_epoch),
            .bcnav = .init(stored.bds, stored.selected.bcnav, stored.bds_epoch),
            .gnav = .init(stored.glonass, stored.selected.gnav),
        };
    }
};

pub const PreparedMessages = struct {
    publications: publications.Prepared,
    almanacs: Almanacs,
    systems: systems.Systems,
};
