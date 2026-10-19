const core = @import("../../core.zig");
const gnss = @import("../../gnss.zig");
const bundle = @import("../../bundle.zig");
const gps = gnss.gps;
const galileo = gnss.galileo;
const bds = gnss.bds;
const glonass = gnss.glonass;

const Bundle = bundle.Bundle;
const NavFamily = core.types.NavFamily;
const SatId = core.types.SatId;
const GpsTime = core.time.GpsTime;
const Broadcast = @import("../ionosphere.zig").Broadcast;

/// Each satellite's content of a family on the leg in force at `t`.
fn contents(b: *const Bundle, comptime family: NavFamily, t: GpsTime, out: []?*const @FieldType(gnss.content.Content, @tagName(family))) void {
    for (out, 0..) |*slot, i| {
        const content = b.plan.contentAt(SatId.at(family.system(), i), family, t) orelse continue;
        slot.* = &@field(content, @tagName(family));
    }
}

pub fn lnav(b: *const Bundle, broadcast: *const Broadcast, publications: []const gps.messages.Publication, configuration: [63]u3, t: GpsTime) gps.lnav.Set.Inputs {
    const set = &b.navigation;
    var in: gps.lnav.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.gps,
        .klobuchar = broadcast.klobuchar,
        .utc = set.utc(.gps, t, b.plan.leap),
        .publications = publications,
        .configuration = configuration,
    };
    contents(b, .lnav, t, &in.eph);
    return in;
}

fn cnvx(b: *const Bundle, broadcast: *const Broadcast, comptime family: NavFamily, t: GpsTime) gps.cnvx.Inputs {
    const set = &b.navigation;
    var in: gps.cnvx.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.gps,
        .klobuchar = broadcast.klobuchar,
        .utc = set.utc(.gps, t, b.plan.leap),
        .eop = set.eop(.gps, t),
        .ggto = .{
            set.timeOffset(.gagp, .gps, t) orelse set.timeOffset(.gagp, .gal, t),
            set.timeOffset(.glgp, .gps, t) orelse set.timeOffset(.glgp, .glo, t),
        },
        .t = t,
    };
    contents(b, family, t, &in.eph);
    return in;
}

pub fn cnav(b: *const Bundle, broadcast: *const Broadcast, publications: []const gps.messages.Publication, corrections: ?gps.dc.Source, t: GpsTime) gps.cnav.Set.Inputs {
    return .{ .shared = cnvx(b, broadcast, .cnav, t), .publications = publications, .dc = corrections };
}

pub fn cnav2(b: *const Bundle, broadcast: *const Broadcast, publications: []const gps.cnav2.publications.PreparedPublication, configuration: ?*const gps.cnav2.publications.Payload, corrections: ?gps.dc.Source, t: GpsTime) gps.cnav2.Set.Inputs {
    return .{ .shared = cnvx(b, broadcast, .cnav2, t), .publications = publications, .configuration = configuration, .dc = corrections };
}

pub fn d1d2(b: *const Bundle, broadcast: *const Broadcast, service: ?bds.d1d2.augmentation.Source, t: GpsTime) bds.d1d2.Set.Inputs {
    const set = &b.navigation;
    var in: bds.d1d2.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.bds,
        .klobuchar = broadcast.bds_klobuchar,
        .utc = set.utc(.bds, t, b.plan.leap),
        .offsets = .{ set.timeOffset(.bdgp, .bds, t), set.timeOffset(.bdga, .bds, t), set.timeOffset(.bdgl, .bds, t) },
        .service = service,
        .t = t,
    };
    contents(b, .d1d2, t, &in.eph);
    return in;
}

pub fn bcnav(b: *const Bundle, broadcast: *const Broadcast, comptime family: NavFamily, t: GpsTime) bds.bcnav.Inputs {
    comptime {
        if (family != .bcnav1 and family != .bcnav2 and family != .bcnav3) @compileError("B-CNAV inputs require a B-CNAV message family");
    }
    const set = &b.navigation;
    var in: bds.bcnav.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.bds,
        .bdgim = broadcast.bdgim,
        .utc = set.utc(.bds, t, b.plan.leap),
        .eop = set.eop(.bds, t),
        .offsets = .{ set.timeOffset(.bdgp, .bds, t), set.timeOffset(.bdga, .bds, t), set.timeOffset(.bdgl, .bds, t) },
        .t = t,
    };
    contents(b, family, t, &in.eph);
    return in;
}

pub fn gnav(b: *const Bundle, t: GpsTime) glonass.gnav.Set.Inputs {
    const set = &b.navigation;
    var in: glonass.gnav.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.glonass,
        .time_utc = set.timeOffset(.glut, .glo, t),
        .time_gps = set.timeOffset(.glgp, .glo, t),
        .eop = set.eop(null, t),
        .t = t,
        .leap = b.plan.leap,
    };
    contents(b, .gnav, t, &in.eph);
    return in;
}

pub fn inav(b: *const Bundle, broadcast: *const Broadcast, publications: []const galileo.inav.ism.PreparedPublication, t: GpsTime) galileo.inav.Set.Inputs {
    const set = &b.navigation;
    var in: galileo.inav.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.galileo,
        .nequick = broadcast.nequick,
        .utc = set.utc(.gal, t, b.plan.leap),
        .ggto = set.timeOffset(.gagp, .gal, t),
        .publications = publications,
        .t = t,
    };
    contents(b, .inav, t, &in.eph);
    return in;
}

pub fn fnav(b: *const Bundle, broadcast: *const Broadcast, t: GpsTime) galileo.fnav.Set.Inputs {
    const set = &b.navigation;
    var in: galileo.fnav.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.galileo,
        .nequick = broadcast.nequick,
        .utc = set.utc(.gal, t, b.plan.leap),
        .ggto = set.timeOffset(.gagp, .gal, t),
        .t = t,
    };
    contents(b, .fnav, t, &in.eph);
    return in;
}
