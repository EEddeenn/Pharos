const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const bundle = shared.bundle;
const messages = shared.stage.messages;
const value = @import("value.zig");
const Availability = value.Availability;
const Reason = value.Reason;
const Instant = value.Instant;
const Interval = value.Interval;
const GpsTime = core.time.GpsTime;
const SatId = core.types.SatId;
const Signal = core.types.Signal;
const NavFamily = core.types.NavFamily;

const lnav_units = .{ .healthBits = "bits", .integrityStatusIndex = "index", .uraIndex = "index", .l2CodesIndex = "index", .iodeIndex = "index", .iodcIndex = "index", .tgdL1caS = "s" };
const cnav_units = .{ .uraEdIndex = "index", .uraNed0Index = "index", .uraNed1Index = "index", .uraNed2Index = "index", .tgdS = "s", .iscL1caS = "s", .iscL2cS = "s", .iscL5i5S = "s", .iscL5q5S = "s", .iscL1cdS = "s", .iscL1cpS = "s" };
const inav_units = .{ .sisaIndex = "index", .iodNavIndex = "index", .e1bHealthIndex = "index", .e5bHealthIndex = "index", .bgdE1e5aS = "s", .bgdE1e5bS = "s" };
const fnav_units = .{ .sisaIndex = "index", .iodNavIndex = "index", .e5aHealthIndex = "index", .bgdE1e5aS = "s" };
const d1d2_units = .{ .uraIndex = "index", .aodcIndex = "index", .aodeIndex = "index", .tgdB1iS = "s", .tgdB2iS = "s" };
const bcnav_units = .{ .sismaiIndex = "index", .sisaiOeIndex = "index", .sisaiOcbIndex = "index", .sisaiOc1Index = "index", .sisaiOc2Index = "index", .iodeIndex = "index", .iodcIndex = "index", .tgdB1cpS = "s", .iscB1cdS = "s", .tgdB2apS = "s", .iscB2adS = "s", .tgdB2biS = "s" };
const gnav_units = .{ .ftIndex = "index", .enIndex = "index", .pIndex = "index", .preparedP1Index = "index", .mIndex = "index", .frequencyChannel = "index", .deltaTauNS = "s" };
const gpsism_units = .{ .tCorrelIndex = "index", .bNomIndex = "index", .gammaNomIndex = "index", .rSatIndex = "index", .pConstIndex = "index", .mfdIndex = "index", .maskHex = "hex" };
const gpspublication_units = .{ .configuration = "index" };
const inavpublication_units = .{ .testMessageHex = "hex" };
const messages_units = .{ .configurationIndex = "index" };
const service_units = .{ .clockIntervalS = "s", .orbitIntervalS = "s" };

pub const Lnav = struct {
    units: @TypeOf(lnav_units) = lnav_units,
    healthBits: u6,
    integrityStatusIndex: u1,
    alert: bool,
    uraIndex: u4,
    l2CodesIndex: u2,
    l2pData: bool,
    fitInterval: bool,
    iodeIndex: u16,
    iodcIndex: u16,
    tgdL1caS: ?f64,
};
pub const Cnav = struct {
    units: @TypeOf(cnav_units) = cnav_units,
    uraEdIndex: i5,
    uraNed0Index: i5,
    uraNed1Index: u3,
    uraNed2Index: u3,
    l1Health: bool,
    l2Health: ?bool,
    l5Health: ?bool,
    integrityStatus: ?bool,
    l2cPhasing: ?bool,
    alert: ?bool,
    tgdS: f64,
    iscL1caS: ?f64,
    iscL2cS: ?f64,
    iscL5i5S: ?f64,
    iscL5q5S: ?f64,
    iscL1cdS: ?f64,
    iscL1cpS: ?f64,
};
pub const Inav = struct {
    units: @TypeOf(inav_units) = inav_units,
    sisaIndex: u8,
    iodNavIndex: u10,
    e1bHealthIndex: u2,
    e5bHealthIndex: u2,
    e1bDataInvalid: bool,
    e5bDataInvalid: bool,
    bgdE1e5aS: ?f64,
    bgdE1e5bS: ?f64,
};
pub const Fnav = struct {
    units: @TypeOf(fnav_units) = fnav_units,
    sisaIndex: u8,
    iodNavIndex: u10,
    e5aHealthIndex: u2,
    e5aDataInvalid: bool,
    clockAvailable: bool,
    bgdE1e5aS: ?f64,
};
pub const D1d2 = struct {
    units: @TypeOf(d1d2_units) = d1d2_units,
    format: enum { d1, d2 },
    satH1: bool,
    uraIndex: u4,
    aodcIndex: u5,
    aodeIndex: u5,
    tgdB1iS: f64,
    tgdB2iS: f64,
};
pub const Bcnav = struct {
    units: @TypeOf(bcnav_units) = bcnav_units,
    sismaiIndex: u4,
    sisaiOeIndex: u5,
    sisaiOcbIndex: u5,
    sisaiOc1Index: u3,
    sisaiOc2Index: u3,
    b1c: ?gnss.bds.records.BcnavSignalFlags,
    b2a: ?gnss.bds.records.BcnavSignalFlags,
    b2b: ?gnss.bds.records.BcnavSignalFlags,
    b1cHealth: ?bool,
    b2aHealth: ?bool,
    b2bHealth: ?bool,
    satType: gnss.bds.records.SatType,
    iodeIndex: u16,
    iodcIndex: u16,
    tgdB1cpS: ?f64,
    iscB1cdS: ?f64,
    tgdB2apS: ?f64,
    iscB2adS: ?f64,
    tgdB2biS: ?f64,
};
pub const Gnav = struct {
    units: @TypeOf(gnav_units) = gnav_units,
    health: bool,
    almanacHealth: ?bool,
    ftIndex: ?u4,
    enIndex: u5,
    pIndex: ?u2,
    preparedP1Index: u2,
    p4: ?bool,
    mIndex: ?u2,
    frequencyChannel: i8,
    deltaTauNS: ?f64,
};
pub const Parameters = union(enum) { lnav: Lnav, cnav: Cnav, cnav2: Cnav, inav: Inav, fnav: Fnav, d1d2: D1d2, bcnav1: Bcnav, bcnav2: Bcnav, bcnav3: Bcnav, gnav: Gnav };

pub const GpsIsm = struct {
    units: @TypeOf(gpsism_units) = gpsism_units,
    reference: Instant,
    constellation: gnss.gps.ism.Constellation,
    service: gnss.gps.ism.Service,
    maskHex: []const u8,
    tCorrelIndex: u4,
    bNomIndex: u4,
    gammaNomIndex: u4,
    rSatIndex: u4,
    pConstIndex: u4,
    mfdIndex: u4,
    availableAtQuery: bool,
};
pub const GpsPublication = struct {
    units: @TypeOf(gpspublication_units) = gpspublication_units,
    integrity: ?struct {
        isfIndex: u1,
        alertMaskHex: []const u8,
        targetAlert: bool,
        units: @TypeOf(.{ .isfIndex = "index", .alertMaskHex = "hex" }) = .{ .isfIndex = "index", .alertMaskHex = "hex" },
    } = null,
    text: ?[]const u8 = null,
    configuration: ?[63]u3 = null,
    ism: ?GpsIsm = null,
    differential: ?struct {
        udraIndex: i5,
        udraRateIndex: i5,
        units: @TypeOf(.{ .udraIndex = "index", .udraRateIndex = "index" }) = .{ .udraIndex = "index", .udraRateIndex = "index" },
    } = null,
};
pub const InavPublication = struct {
    units: @TypeOf(inavpublication_units) = inavpublication_units,
    kind: std.meta.Tag(gnss.galileo.inav.ism.Ism),
    testMessageHex: ?[]const u8 = null,
    horizontal: ?struct {
        reference: Instant,
        maskMsb: bool,
        maskHex: []const u8,
        pConstIndex: u4,
        pSatIndex: u4,
        uraIndex: u4,
        ureIndex: u4,
        bNomIndex: u4,
        tValidityIndex: u4,
        units: @TypeOf(.{ .maskHex = "hex", .pConstIndex = "index", .pSatIndex = "index", .uraIndex = "index", .ureIndex = "index", .bNomIndex = "index", .tValidityIndex = "index" }) = .{ .maskHex = "hex", .pConstIndex = "index", .pSatIndex = "index", .uraIndex = "index", .ureIndex = "index", .bNomIndex = "index", .tValidityIndex = "index" },
    } = null,
};
pub const D2Publication = struct {
    integrity: ?struct {
        check: gnss.bds.d1d2.augmentation.Check,
        satellites: [63]?struct { ruraiIndex: u4, udreiIndex: u4, units: @TypeOf(.{ .ruraiIndex = "index", .udreiIndex = "index" }) = .{ .ruraiIndex = "index", .udreiIndex = "index" } },
    } = null,
    grid: ?struct {
        check: gnss.bds.d1d2.augmentation.Check,
        giveiIndex: [320]u4,
        monitored: [320]bool,
        units: @TypeOf(.{ .giveiIndex = "index" }) = .{ .giveiIndex = "index" },
    } = null,
};
pub const Publication = struct {
    availability: Availability = .not_applicable,
    reason: ?Reason = .family_has_no_publications,
    timing: enum { publication_interval } = .publication_interval,
    validity: ?Interval = null,
    contentValidity: ?Interval = null,
    gps: ?GpsPublication = null,
    inav: ?InavPublication = null,
    d2: ?D2Publication = null,
};
pub const Messages = struct {
    units: @TypeOf(messages_units) = messages_units,
    availability: Availability = .unavailable,
    reason: ?Reason = .no_navigation_record,
    family: NavFamily,
    semantics: enum { prepared_parameters } = .prepared_parameters,
    validity: ?Interval = null,
    toe: ?Instant = null,
    toc: ?Instant = null,
    parameters: ?Parameters = null,
    orbit: ?value.Orbit = null,
    glonassOrbit: ?value.GlonassOrbit = null,
    publication: Publication = .{},
    configurationIndex: ?u3 = null,
};
pub const Service = struct {
    units: @TypeOf(service_units) = service_units,
    availability: Availability = .not_applicable,
    reason: ?Reason = null,
    kind: ?enum { has, ppp_b2b, d2, gps_differential } = null,
    enabled: bool = false,
    status: ?[]const u8 = null,
    clockIntervalS: ?u32 = null,
    orbitIntervalS: ?u32 = null,
    outputAvailability: Availability = .unavailable,
    outputReason: Reason = .service_not_enabled,
    payloadAvailability: Availability = .unavailable,
    payloadReason: Reason = .correction_payload_not_inspected,
};
pub const Needs = struct { messages: bool, service: bool };
pub const Result = struct { messages: ?Messages = null, service: ?Service = null };

fn gpsText(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (input) |c| {
        if (c == gnss.gps.text.degree) {
            out.writer.writeAll("°") catch return error.OutOfMemory;
        } else {
            out.writer.writeByte(c) catch return error.OutOfMemory;
        }
    }
    return out.written();
}

fn gpsPublication(arena: std.mem.Allocator, src: gnss.gps.messages.Sources, prn: u8, t: GpsTime, family: NavFamily) !GpsPublication {
    var out: GpsPublication = .{};
    if (src.integrity) |v| out.integrity = .{ .isfIndex = v.isf, .alertMaskHex = try arena.print("{x:0>8}", .{v.alert}), .targetAlert = v.alerts(prn) };
    if (src.text) |v| {
        out.text = try gpsText(arena, v);
    }
    if (family != .cnav) out.configuration = src.configuration;
    if (family != .lnav) {
        if (src.ism) |v| out.ism = .{
            .reference = .of(v.reference),
            .constellation = v.constellation,
            .service = v.service,
            .maskHex = try arena.print("{x:0>16}", .{v.mask}),
            .tCorrelIndex = v.t_correl,
            .bNomIndex = v.b_nom,
            .gammaNomIndex = v.gamma_nom,
            .rSatIndex = v.r_sat,
            .pConstIndex = v.p_const,
            .mfdIndex = v.mfd,
            .availableAtQuery = !t.lessThan(v.reference),
        };
        if (src.differential) |v| out.differential = .{ .udraIndex = v.udra, .udraRateIndex = v.udra_rate };
    }
    return out;
}

fn publications(arena: std.mem.Allocator, b: *const bundle.Bundle, prepared: messages.Messages, sat: SatId, family: NavFamily, t: GpsTime) !Publication {
    var out: Publication = .{ .availability = .unavailable, .reason = .no_active_publication };
    switch (family) {
        .lnav, .cnav => {
            const p = gnss.gps.messages.Publication.at(prepared.gps, t) orelse return out;
            out.validity = .of(b.scenario.start, p.from, p.until);
            out.gps = try gpsPublication(arena, p.content, sat.prn(), t, family);
        },
        .cnav2 => {
            const p = gnss.gps.cnav2.publications.PreparedPublication.at(prepared.cnav2, t) orelse return out;
            out.validity = .of(b.scenario.start, p.from, p.until);
            out.gps = try gpsPublication(arena, p.content.sources, sat.prn(), t, family);
        },
        .inav => {
            const p = gnss.galileo.inav.ism.PreparedPublication.at(prepared.inav, t) orelse return out;
            const raw = gnss.galileo.inav.ism.Publication.at(b.scenario.messages.inav, t) orelse return out;
            out.validity = .of(b.scenario.start, p.from, p.until);
            var content: InavPublication = .{ .kind = std.meta.activeTag(raw.content) };
            switch (raw.content) {
                .no_data => {},
                .test_message => |v| content.testMessageHex = try arena.print("{x:0>22}", .{v}),
                .horizontal => |v| content.horizontal = .{
                    .reference = .of(v.reference),
                    .maskMsb = v.mask_msb,
                    .maskHex = try arena.print("{x:0>8}", .{v.mask}),
                    .pConstIndex = v.p_const,
                    .pSatIndex = v.p_sat,
                    .uraIndex = v.ura,
                    .ureIndex = v.ure,
                    .bNomIndex = v.b_nom,
                    .tValidityIndex = v.t_validity,
                },
            }
            out.inav = content;
            if (p.content.validity) |v| {
                out.contentValidity = .of(b.scenario.start, v.from, v.until);
                if (!p.content.available(t)) {
                    out.reason = if (t.lessThan(v.from)) .publication_not_yet_valid else .publication_expired;
                    return out;
                }
            }
        },
        .d1d2 => {
            if (!gnss.bds.records.isGeo(sat.prn())) return .{};
            const p = gnss.bds.d1d2.augmentation.PreparedPublication.at(prepared.d2, t) orelse return out;
            out.validity = .of(b.scenario.start, p.from, p.until);
            var content: D2Publication = .{};
            if (p.content.integrity) |v| {
                content.integrity = .{ .check = v.check, .satellites = @splat(null) };
                for (v.svid[0..v.count], v.indices[0..v.count]) |prn, indices| content.integrity.?.satellites[prn - 1] = .{ .ruraiIndex = indices.rurai, .udreiIndex = indices.udrei };
            }
            if (p.content.grid) |v| content.grid = .{ .check = v.check, .giveiIndex = v.givei, .monitored = v.monitored };
            out.d2 = content;
        },
        else => return .{},
    }
    out.availability = .available;
    out.reason = null;
    return out;
}

fn serviceValue(b: *const bundle.Bundle, sat: SatId, signal: Signal, family: NavFamily, sampled: bool, publication_enabled: bool) Service {
    var out: Service = .{};
    if (signal == .e6) {
        out.kind = .has;
        if (b.scenario.has) |h| {
            out.enabled = true;
            out.status = h.status.name();
            out.clockIntervalS = h.clock_interval_s;
            out.orbitIntervalS = h.orbit_interval_s;
        }
    } else if (signal == .b2b and gnss.bds.allocation.carriesPppB2b(sat.prn())) {
        out.kind = .ppp_b2b;
        if (b.scenario.ppp_b2b) |s| {
            out.enabled = true;
            out.clockIntervalS = s.clock_interval_s;
            out.orbitIntervalS = s.orbit_interval_s;
        }
    } else if (family == .d1d2 and gnss.bds.records.isGeo(sat.prn())) {
        out.kind = .d2;
        out.enabled = publication_enabled;
    } else if (family == .cnav or family == .cnav2) {
        out.kind = .gps_differential;
        out.enabled = publication_enabled;
    } else return out;
    out.availability = .available;
    out.reason = if (out.enabled) null else .service_not_enabled;
    out.outputReason = if (!out.enabled)
        .service_not_enabled
    else if (!sampled)
        .no_samples
    else if (!b.scenario.signals.contains(signal))
        .signal_not_enabled
    else
        .correction_payload_not_inspected;
    return out;
}

fn servicePublication(prepared: messages.Messages, sat: SatId, family: NavFamily, t: GpsTime) bool {
    return switch (family) {
        .d1d2 => gnss.bds.records.isGeo(sat.prn()) and gnss.bds.d1d2.augmentation.PreparedPublication.at(prepared.d2, t) != null,
        .cnav => if (gnss.gps.messages.Publication.at(prepared.gps, t)) |p| p.content.differential != null else false,
        .cnav2 => if (gnss.gps.cnav2.publications.PreparedPublication.at(prepared.cnav2, t)) |p| p.content.sources.differential != null else false,
        else => false,
    };
}

pub fn project(arena: std.mem.Allocator, b: *const bundle.Bundle, payload: *const gnss.payload.Payload, prepared: messages.Messages, set: ?messages.MessageSet, boundary: GpsTime, until: GpsTime, query_time: GpsTime, sat: SatId, signal: Signal, family: NavFamily, sampled: bool, needs: Needs) error{OutOfMemory}!Result {
    return .{
        .messages = if (needs.messages) try projectMessages(arena, b, payload, prepared, set, boundary, until, query_time, sat, signal, family, sampled) else null,
        .service = if (needs.service) serviceValue(b, sat, signal, family, sampled, sampled and b.scenario.signals.contains(signal) and servicePublication(prepared, sat, family, query_time)) else null,
    };
}

fn projectMessages(arena: std.mem.Allocator, b: *const bundle.Bundle, payload: *const gnss.payload.Payload, prepared: messages.Messages, set: ?messages.MessageSet, boundary: GpsTime, until: GpsTime, query_time: GpsTime, sat: SatId, signal: Signal, family: NavFamily, sampled: bool) error{OutOfMemory}!Messages {
    var out: Messages = .{ .family = family };
    if (!sampled) {
        out.reason = .no_samples;
        return out;
    }
    if (!b.scenario.signals.contains(signal)) {
        out.reason = .signal_not_enabled;
        return out;
    }
    out.publication = try publications(arena, b, prepared, sat, family, query_time);
    if (!payload.carries(sat, family)) {
        out.reason = .satellite_not_broadcast;
        return out;
    }
    out.validity = .of(b.scenario.start, boundary, until);
    const i = sat.prn() - 1;
    switch (family) {
        inline else => |f| {
            const prepared_set = set orelse return out;
            const values = @field(prepared_set, @tagName(f)).set;
            switch (f) {
                .lnav => {
                    const eph = values.eph[i] orelse return out;
                    const x = eph.extra.lnav;
                    const declared = gnss.gps.messages.Publication.at(prepared.gps, query_time);
                    const integrity = if (declared) |p| p.content.integrity else null;
                    out.toe = .of(eph.toe);
                    out.toc = .of(eph.toc);
                    out.orbit = .of(eph.parameters());
                    out.parameters = .{ .lnav = .{
                        .healthBits = x.health,
                        .integrityStatusIndex = if (integrity) |v| v.isf else 0,
                        .alert = if (integrity) |v| v.alerts(sat.prn()) else false,
                        .uraIndex = x.ura_index,
                        .l2CodesIndex = x.l2_codes,
                        .l2pData = x.l2p_data,
                        .fitInterval = x.fit_interval,
                        .iodeIndex = eph.iode,
                        .iodcIndex = eph.iodc,
                        .tgdL1caS = eph.group_delay.get(.tgd_l1ca),
                    } };
                    out.configurationIndex = @truncate(values.health.as_config[i]);
                    if (out.publication.gps) |g| if (g.configuration) |codes| {
                        out.configurationIndex = codes[i];
                    };
                },
                .cnav, .cnav2 => {
                    const sv = values.data.sv[i] orelse return out;
                    if (sv.misfit != null) {
                        out.reason = .unrepresentable_parameters;
                        return out;
                    }
                    const p = sv.parameters;
                    const declared = if (f == .cnav) blk: {
                        const publication = gnss.gps.messages.Publication.at(prepared.gps, query_time) orelse break :blk null;
                        break :blk &publication.content;
                    } else blk: {
                        const publication = gnss.gps.cnav2.publications.PreparedPublication.at(prepared.cnav2, query_time) orelse break :blk null;
                        break :blk &publication.content.sources;
                    };
                    const flags = if (f == .cnav) gnss.gps.cnvx.cnavFlags(&sv, if (declared) |c| c.integrity else null, sat.prn()) else null;
                    const isf = if (f == .cnav2) values.isfAt(&sv, query_time) else if (flags) |v| v.integrity_status else null;
                    out.toe = .of(p.eph.toe);
                    out.toc = .of(p.eph.toc);
                    out.orbit = .of(p.eph);
                    out.parameters = @unionInit(Parameters, @tagName(f), .{
                        .uraEdIndex = p.ura.ed,
                        .uraNed0Index = p.ura.ned0,
                        .uraNed1Index = p.ura.ned1,
                        .uraNed2Index = p.ura.ned2,
                        .l1Health = p.l1_health,
                        .l2Health = if (f == .cnav) p.l2_health else null,
                        .l5Health = if (f == .cnav) p.l5_health else null,
                        .integrityStatus = isf,
                        .l2cPhasing = if (flags) |v| v.l2c_phasing else null,
                        .alert = if (flags) |v| v.alert else null,
                        .tgdS = p.tgd,
                        .iscL1caS = if (f == .cnav) p.isc_l1ca else null,
                        .iscL2cS = if (f == .cnav) p.isc_l2c else null,
                        .iscL5i5S = if (f == .cnav) p.isc_l5i5 else null,
                        .iscL5q5S = if (f == .cnav) p.isc_l5q5 else null,
                        .iscL1cdS = if (f == .cnav2) p.isc_l1cd else null,
                        .iscL1cpS = if (f == .cnav2) p.isc_l1cp else null,
                    });
                    if (f == .cnav2) {
                        out.configurationIndex = prepared.configuration[i];
                        if (declared) |d| if (d.configuration) |codes| {
                            out.configurationIndex = codes[i];
                        };
                    }
                    if (isf == null) {
                        out.reason = .missing_integrity;
                        return out;
                    }
                },
                .inav, .fnav => {
                    const sv = values.sv[i] orelse return out;
                    const eph = sv.eph;
                    out.toe = .of(eph.toe);
                    out.toc = .of(eph.toc);
                    out.orbit = .of(eph.parameters());
                    if (f == .inav) {
                        const x = eph.extra.inav;
                        out.parameters = .{ .inav = .{
                            .sisaIndex = x.sisa_index,
                            .iodNavIndex = x.iod_nav,
                            .e1bHealthIndex = x.e1b_hs,
                            .e5bHealthIndex = x.e5b_hs,
                            .e1bDataInvalid = x.e1b_dvs,
                            .e5bDataInvalid = x.e5b_dvs,
                            .bgdE1e5aS = eph.group_delay.get(.bgd_e1e5a),
                            .bgdE1e5bS = eph.group_delay.get(.bgd_e1e5b),
                        } };
                    } else {
                        const x = eph.extra.fnav;
                        out.parameters = .{ .fnav = .{
                            .sisaIndex = x.sisa_index,
                            .iodNavIndex = x.iod_nav,
                            .e5aHealthIndex = x.e5a_hs,
                            .e5aDataInvalid = x.e5a_dvs,
                            .clockAvailable = sv.clock_fits,
                            .bgdE1e5aS = eph.group_delay.get(.bgd_e1e5a),
                        } };
                    }
                },
                .d1d2 => {
                    const sv = values.sv[i] orelse return out;
                    const x = sv.at(query_time).metadata;
                    out.toe = .of(sv.eph.toe);
                    out.toc = .of(sv.eph.toc);
                    out.orbit = .of(sv.eph);
                    out.parameters = .{ .d1d2 = .{
                        .format = if (gnss.bds.records.isGeo(sat.prn())) .d2 else .d1,
                        .satH1 = x.sat_h1,
                        .uraIndex = x.urai,
                        .aodcIndex = x.aodc,
                        .aodeIndex = x.aode,
                        .tgdB1iS = x.tgd1,
                        .tgdB2iS = x.tgd2,
                    } };
                },
                .bcnav1, .bcnav2, .bcnav3 => {
                    if (f == .bcnav3 and gnss.bds.allocation.carriesPppB2b(sat.prn())) {
                        out.availability = .not_applicable;
                        out.reason = .service_only;
                        return out;
                    }
                    const sv = values.data.sv[i] orelse return out;
                    out.toe = .of(sv.ephemeris.eph.toe);
                    out.toc = .of(sv.ephemeris.eph.toc);
                    out.orbit = .of(sv.ephemeris.eph);
                    out.parameters = @unionInit(Parameters, @tagName(f), .{
                        .sismaiIndex = sv.sismai,
                        .sisaiOeIndex = sv.sisai_oe,
                        .sisaiOcbIndex = sv.sisai_ocb,
                        .sisaiOc1Index = sv.sisai_oc1,
                        .sisaiOc2Index = sv.sisai_oc2,
                        .b1c = if (f != .bcnav3) sv.b1c else null,
                        .b2a = if (f == .bcnav2) sv.b2a else null,
                        .b2b = if (f == .bcnav3) sv.b2b else null,
                        .b1cHealth = if (f == .bcnav1) sv.hs_b1c else null,
                        .b2aHealth = if (f == .bcnav2) sv.hs_b2a else null,
                        .b2bHealth = if (f == .bcnav3) sv.hs_b2b else null,
                        .satType = sv.ephemeris.sat_type,
                        .iodeIndex = sv.ephemeris.iode,
                        .iodcIndex = sv.ephemeris.iodc,
                        .tgdB1cpS = if (f != .bcnav3) sv.tgd_b1cp else null,
                        .iscB1cdS = if (f == .bcnav1) sv.isc_b1cd else null,
                        .tgdB2apS = if (f != .bcnav3) sv.tgd_b2ap else null,
                        .iscB2adS = if (f == .bcnav2) sv.isc_b2ad else null,
                        .tgdB2biS = if (f == .bcnav3) sv.tgd_b2bi else null,
                    });
                },
                .gnav => {
                    const eph = values.eph[i] orelse return out;
                    out.toe = .of(eph.tb);
                    out.toc = out.toe;
                    out.glonassOrbit = .of(eph);
                    out.parameters = .{ .gnav = .{
                        .health = eph.health,
                        .almanacHealth = eph.almanac_health,
                        .ftIndex = eph.ft,
                        .enIndex = eph.en,
                        .pIndex = eph.p,
                        .preparedP1Index = values.p1[i] orelse eph.p1,
                        .p4 = eph.p4,
                        .mIndex = eph.m,
                        .frequencyChannel = eph.freq.k,
                        .deltaTauNS = values.delta_tau_n[i],
                    } };
                },
                .cnav_has => {
                    out.availability = .not_applicable;
                    out.reason = .service_only;
                    return out;
                },
            }
            prepared_set.requireData(sat.prn()) catch |err| {
                out.reason = switch (err) {
                    error.MissingEarthOrientation => .missing_eop,
                    error.MissingTimeOffset => .missing_time_offset,
                    error.MissingUtcParameters => .missing_utc,
                };
                return out;
            };
        },
    }
    out.availability = .available;
    out.reason = null;
    return out;
}
