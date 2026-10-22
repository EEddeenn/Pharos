const system_data = @import("domain/navigation/system_data");
const field = @import("base/binary/field");
const content = @import("domain/messages/gps/lnav/content");
const records = @import("domain/navigation/records");
const fields = @import("domain/messages/gps/lnav/fields");
const publications = @import("domain/messages/gps/cnav2/publications");
const time = @import("domain/time/gps");
const almanac_grid = @import("domain/navigation/almanac_epoch");
const Klobuchar = @import("domain/propagation/ionosphere/klobuchar").Model;
const SatSet = @import("domain/gnss_types").SatSet;
const Alm = records.KeplerAlmanac;
const health_unusable: u6 = 0x3F;
pub const as_flag: u4 = 0b1000;

pub const Almanacs = struct {
    entries: [32]?*const Alm,
    health: fields.Health,

    pub fn init(records_in: []const Alm, selected: SatSet, epoch: time.GpsTime, configuration: *const [63]u3) Almanacs {
        var out: Almanacs = .{ .entries = @splat(null), .health = undefined };
        for (records_in) |*a| if (selected.contains(a.sat)) {
            out.entries[a.sat.index] = a;
        };
        out.health = healthOf(&out.entries, epoch, configuration);
        return out;
    }

    fn healthOf(alm: *const [32]?*const Alm, epoch: time.GpsTime, configuration: *const [63]u3) fields.Health {
        var h: fields.Health = .{ .toa = @intCast(epoch.msOfWeek() / almanac_grid.toa_step_ms), .wna = @intCast(@mod(epoch.week(), time.week_modulus_8)), .sv = @splat(health_unusable), .as_config = undefined };
        for (&h.as_config, configuration[0..32]) |*term, code| term.* = as_flag | @as(u4, code);
        for (alm, 0..) |entry, i| {
            const a = entry orelse continue;
            const summary: u6 = if (a.health >> 5 != 0) 0x20 else 0;
            h.sv[i] = summary | @as(u6, @intCast(a.health & 0x1F));
        }
        return h;
    }
};

pub const Page18Codes = field.Decoded(fields.Page18, &fields.page18);
pub const System = struct { page18: ?Page18Codes };

pub const Set = struct {
    eph: [32]?*const content.Parameters,
    almanacs: *const Almanacs,
    system: *const System,
    publications: []const publications.PreparedPublication = &.{},

    pub const Inputs = struct {
        eph: [32]?*const content.Content,
        almanacs: *const Almanacs,
        system: *const System,
        publications: []const publications.PreparedPublication = &.{},
    };

    pub fn init(input: Inputs) Set {
        var out: Set = .{ .eph = @splat(null), .almanacs = input.almanacs, .system = input.system, .publications = input.publications };
        for (input.eph, &out.eph) |entry, *slot| slot.* = if (entry) |c| c.value() else null;
        return out;
    }
};

pub fn page18(input: ?system_data.UtcParams, klobuchar: Klobuchar) ?Page18Codes {
    const source = input orelse return null;
    const leap = source.leap orelse return null;
    if (source.a2 != 0 or source.tot_s % 4096 != 0) return null;
    const candidate = fields.Page18.init(.of(klobuchar), source, leap);
    return switch (field.prepare(fields.Page18, &fields.page18, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn projectPage18(source: system_data.UtcParams, klobuchar: Klobuchar) Page18Codes {
    const candidate = fields.Page18.init(.of(klobuchar), source, source.leap.?);
    return field.project(fields.Page18, &fields.page18, &candidate);
}
