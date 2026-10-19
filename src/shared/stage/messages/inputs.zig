const core = @import("../../core.zig");
const gnss = @import("../../gnss.zig");
const track = @import("../../track.zig");
const bundle = @import("../../bundle.zig");
const gps = gnss.gps;
const galileo = gnss.galileo;
const bds = gnss.bds;
const glonass = gnss.glonass;

const Bundle = bundle.Bundle;
const Kepler = gnss.reference.Kepler;
const NavFamily = core.types.NavFamily;
const SatId = core.types.SatId;
const GpsTime = core.time.GpsTime;
const Broadcast = @import("../ionosphere.zig").Broadcast;
const Payload = gnss.payload.Payload;

pub fn recordOf(b: *const Bundle, payload: *const Payload, family: NavFamily, sat: SatId, t: GpsTime) ?Kepler {
    if (!payload.carries(sat, family)) return null;
    const reference = track.selection.keplerAt(b, sat, t) orelse return null;
    return switch (family) {
        inline .lnav, .inav => |own| if (reference.record.source() == @field(gnss.records.NavSource, @tagName(own))) reference else null,
        .cnav, .cnav2, .fnav, .d1d2, .bcnav1, .bcnav2, .bcnav3 => reference,
        .cnav_has, .gnav => null,
    };
}

fn records(b: *const Bundle, payload: *const Payload, family: NavFamily, t: GpsTime, out: []?Kepler) void {
    for (out, 0..) |*slot, i| slot.* = recordOf(b, payload, family, SatId.at(family.system(), i), t);
}

pub fn lnav(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, publications: []const gps.messages.Publication, configuration: [63]u3, t: GpsTime) gps.lnav.Set.Inputs {
    const set = &b.navigation;
    var in: gps.lnav.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.gps,
        .klobuchar = broadcast.klobuchar,
        .utc = set.utc(.gps, t, b.plan.leap),
        .publications = publications,
        .configuration = configuration,
    };
    records(b, payload, .lnav, t, &in.eph);
    return in;
}

fn cnvx(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, source: gnss.records.NavSource, t: GpsTime) gps.cnvx.Inputs {
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
    records(b, payload, source.family(), t, &in.eph);
    return in;
}

pub fn cnav(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, publications: []const gps.messages.Publication, corrections: ?gps.dc.Source, t: GpsTime) gps.cnav.Set.Inputs {
    return .{ .shared = cnvx(b, payload, broadcast, .cnav, t), .publications = publications, .dc = corrections };
}

pub fn cnav2(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, publications: []const gps.cnav2.publications.PreparedPublication, configuration: ?*const gps.cnav2.publications.Payload, corrections: ?gps.dc.Source, t: GpsTime) gps.cnav2.Set.Inputs {
    return .{ .shared = cnvx(b, payload, broadcast, .cnav2, t), .publications = publications, .configuration = configuration, .dc = corrections };
}

pub const D1d2Reference = struct { record: Kepler, prepared: *const bds.d1d2.Prepared };

pub fn d1d2Reference(b: *const Bundle, payload: *const Payload, sat: SatId, t: GpsTime) ?D1d2Reference {
    const record = recordOf(b, payload, .d1d2, sat, t) orelse return null;
    return .{ .record = record, .prepared = b.plan.d1d2At(sat, t) orelse return null };
}

pub fn d1d2(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, service: ?bds.d1d2.augmentation.Source, t: GpsTime) bds.d1d2.Set.Inputs {
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
    for (&in.eph, 0..) |*slot, i| {
        slot.* = if (d1d2Reference(b, payload, SatId.at(.bds, i), t)) |reference| reference.prepared else null;
    }
    return in;
}

pub fn bcnav(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, comptime family: NavFamily, t: GpsTime) bds.bcnav.Inputs {
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
    records(b, payload, family, t, &in.eph);
    return in;
}

pub fn bcnav3(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, service: ?bds.bcnav3.FrameSource, t: GpsTime) bds.bcnav3.Set.Inputs {
    return .{ .shared = bcnav(b, payload, broadcast, .bcnav3, t), .ppp_b2b = service };
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
    for (&in.eph, &in.p1, &in.delta_tau_n, 0..) |*entry, *p1, *delta_tau_n, i| {
        const sat = SatId.at(.glo, i);
        entry.* = track.selection.glonassAt(b, sat, t);
        const binding = b.plan.bindingAt(sat, t) orelse continue;
        p1.* = binding.glonass_p1;
        delta_tau_n.* = binding.group_delay.get(.delta_tau_n);
    }
    return in;
}

pub fn inav(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, publications: []const galileo.inav.ism.PreparedPublication, t: GpsTime) galileo.inav.Set.Inputs {
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
    records(b, payload, .inav, t, &in.eph);
    return in;
}

pub fn fnav(b: *const Bundle, payload: *const Payload, broadcast: *const Broadcast, t: GpsTime) galileo.fnav.Set.Inputs {
    const set = &b.navigation;
    var in: galileo.fnav.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = b.plan.almanacs.galileo,
        .nequick = broadcast.nequick,
        .utc = set.utc(.gal, t, b.plan.leap),
        .ggto = set.timeOffset(.gagp, .gal, t),
        .t = t,
    };
    records(b, payload, .fnav, t, &in.eph);
    return in;
}
