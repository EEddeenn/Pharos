const records = @import("domain/navigation/records");
const reference = @import("domain/messages/fields/almanac_reference");
const coefficients = @import("domain/messages/fields/klobuchar");
const time_parameters = @import("domain/messages/gps/fields/time");
const Content = @import("domain/messages/gps/cnav_common/content").Content;
const Prns = @import("domain/messages/gps/selection").Prns;
const GpsTime = @import("domain/time/gps").GpsTime;
const SatSet = @import("domain/gnss_types").SatSet;

pub const Almanacs = struct {
    entries: [32]?*const records.KeplerAlmanac = @splat(null),
    reference: reference.Reference,
    prns: Prns = .{},

    pub fn init(records_in: []const records.KeplerAlmanac, selected: SatSet, epoch: GpsTime) Almanacs {
        var out: Almanacs = .{ .reference = .fromTime(epoch, .gps) };
        for (records_in) |*a| if (selected.contains(a.sat)) {
            out.entries[a.sat.index] = a;
        };
        for (out.entries, 1..) |entry, number| if (entry != null) {
            out.prns.list[out.prns.len] = @intCast(number);
            out.prns.len += 1;
        };
        return out;
    }
};

pub const Ggtos = struct {
    list: [2]time_parameters.GgtoCodes = @splat(time_parameters.empty_ggto),
    len: u2 = 0,

    pub fn at(self: *const Ggtos, ordinal: i64) time_parameters.GgtoCodes {
        if (self.len == 0) return time_parameters.empty_ggto;
        return self.list[@intCast(@mod(ordinal, @as(i64, self.len)))];
    }
};

pub const System = struct {
    klobuchar: coefficients.Codes,
    utc: ?time_parameters.UtcCodes,
    eop: ?time_parameters.EopCodes,
    ggto: Ggtos,
};

pub const View = struct {
    sv: [32]?*const Content,
    almanacs: *const Almanacs,
    system: *const System,
};
