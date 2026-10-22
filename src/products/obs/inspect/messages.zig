const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const d1d2_ephemeris = @import("domain/messages/bds/d1d2/ephemeris");
const bcnav_content = @import("domain/messages/bds/bcnav/content");
const records = @import("domain/navigation/records");
const inav_ism = @import("domain/messages/galileo/inav/ism");
const cnav2_publications = @import("domain/messages/gps/cnav2/publications");
const cnav_common_content = @import("domain/messages/gps/cnav_common/content");
const gps_ism = @import("domain/messages/gps/ism");
const gps_publication = @import("domain/messages/gps/publication");
const bds_records = @import("domain/navigation/records/bds");
const model_display = @import("phb/model/display");
const model_publications = @import("simulation/model/publications");
const navigation_reference = @import("domain/navigation/reference");
const message_content = @import("domain/messages/content");
const value = @import("products/obs/inspect/values");
const text = @import("domain/messages/gps/text");
const configuration = @import("simulation/model/config");
const gps_records = @import("domain/navigation/records/gps");
const services = @import("simulation/model/services");

const Payload = @import("domain/signals/payload").Payload;
const Window = @import("simulation/state/sequence").Window;
const FlightPlan = @import("simulation/model/flight_plan").FlightPlan;
const GpsTime = @import("domain/time/gps").GpsTime;

const Availability = value.Availability;
const Reason = value.Reason;
const Instant = value.Instant;
const Interval = value.Interval;
const SatId = gnss_types.SatId;
const Signal = gnss_types.Signal;
const NavFamily = gnss_types.NavFamily;

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
    b1c: ?bds_records.BcnavSignalFlags,
    b2a: ?bds_records.BcnavSignalFlags,
    b2b: ?bds_records.BcnavSignalFlags,
    b1cHealth: ?bool,
    b2aHealth: ?bool,
    b2bHealth: ?bool,
    satType: bds_records.SatType,
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
    constellation: gps_ism.Constellation,
    service: gps_ism.Service,
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
    kind: std.meta.Tag(inav_ism.Ism),
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
        check: augmentation.Check,
        satellites: [63]?struct { ruraiIndex: u4, udreiIndex: u4, units: @TypeOf(.{ .ruraiIndex = "index", .udreiIndex = "index" }) = .{ .ruraiIndex = "index", .udreiIndex = "index" } },
    } = null,
    grid: ?struct {
        check: augmentation.Check,
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
    kind: ?services.Service = null,
    enabled: bool = false,
    status: ?[]const u8 = null,
    clockIntervalS: ?u32 = null,
    orbitIntervalS: ?u32 = null,
    outputAvailability: Availability = .unavailable,
    outputReason: Reason = .service_not_enabled,
    payloadAvailability: Availability = .unavailable,
    payloadReason: Reason = .correction_payload_not_inspected,
};

pub const QueryTarget = struct { time: GpsTime, sat: SatId, signal: Signal, family: NavFamily };

pub const ServiceInspectionInputs = struct {
    plan: services.ServicePlan,
    has: ?configuration.Has,
    ppp_b2b: ?configuration.PppB2b,
    signals: std.EnumSet(Signal),
    publications: ?*const model_publications.Prepared,
};

pub const MessageInspectionInputs = struct {
    start: GpsTime,
    signals: std.EnumSet(Signal),
    flight_plan: *const FlightPlan,
    payload: *const Payload,
    publications: ?*const model_publications.Prepared,
};

pub fn service(input: ServiceInspectionInputs, target: QueryTarget) Service {
    const sat = target.sat;
    const signal = target.signal;
    const family = target.family;
    const publication_enabled = if (input.publications) |prepared| input.signals.contains(signal) and servicePublication(prepared, sat, family, target.time) else false;
    var out: Service = .{};
    if (signal == .e6) {
        out.kind = .has;
        if (input.has) |h| {
            out.enabled = true;
            out.status = h.status.name();
            out.clockIntervalS = h.clock_interval_s;
            out.orbitIntervalS = h.orbit_interval_s;
        }
    } else if (family == .ppp_b2b) {
        out.kind = .ppp_b2b;
        if (input.ppp_b2b) |s| {
            out.enabled = true;
            out.clockIntervalS = s.clock_interval_s;
            out.orbitIntervalS = s.orbit_interval_s;
        }
    } else if (family == .d1d2 and bds_records.isGeo(sat.prn())) {
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
    else if (input.publications == null)
        .no_samples
    else if (!input.signals.contains(signal))
        .signal_not_enabled
    else if (!input.plan.runs(out.kind.?))
        .service_not_enabled
    else
        .correction_payload_not_inspected;
    return out;
}

pub fn message(arena: std.mem.Allocator, input: MessageInspectionInputs, display: *const model_display.Display, target: QueryTarget, window: Window) error{OutOfMemory}!Messages {
    const sat = target.sat;
    const signal = target.signal;
    const family = target.family;
    const query_time = target.time;
    const boundary = window.from;
    var out: Messages = .{ .family = family };
    const prepared = input.publications orelse {
        out.reason = .no_samples;
        return out;
    };
    if (!input.signals.contains(signal)) {
        out.reason = .signal_not_enabled;
        return out;
    }
    out.publication = try publications(arena, input.start, prepared, sat, family, query_time);
    if (!input.payload.carries(sat, family)) {
        out.reason = .satellite_not_broadcast;
        return out;
    }
    out.validity = .of(input.start, boundary, window.until);
    const i = sat.prn() - 1;
    switch (family) {
        inline else => |f| {
            switch (f) {
                .lnav => {
                    const eph = contentOf(input.flight_plan, sat, f, boundary, &out.reason) orelse return out;
                    const declared = cnav2_publications.PreparedPublication.at(prepared.gps, query_time);
                    const integrity = if (declared) |p| p.content.declaration.integrity else null;
                    const selected = display.choice(input.flight_plan.legIdAt(sat, boundary).?);
                    const reference: navigation_reference.Kepler = .{ .record = &display.ephemerides.kepler[selected.reference.kepler], .group_delay = &selected.group_delay };
                    out.toe = .of(eph.eph.toe);
                    out.toc = .of(eph.eph.toc);
                    out.orbit = .of(eph.eph);
                    out.parameters = .{ .lnav = .{
                        .healthBits = eph.health,
                        .integrityStatusIndex = if (integrity) |v| v.isf else 0,
                        .alert = if (integrity) |v| v.alerts(sat.prn()) else false,
                        .uraIndex = eph.ura_index,
                        .l2CodesIndex = eph.l2_codes,
                        .l2pData = eph.l2p_data,
                        .fitInterval = eph.fit_interval,
                        .iodeIndex = eph.iode,
                        .iodcIndex = eph.iodc,
                        .tgdL1caS = reference.delay(.l1ca, .data),
                    } };
                    out.configurationIndex = prepared.configuration[i];
                    if (out.publication.gps) |g| if (g.configuration) |codes| {
                        out.configurationIndex = codes[i];
                    };
                },
                .cnav, .cnav2 => {
                    const sv = contentOf(input.flight_plan, sat, f, boundary, &out.reason) orelse return out;
                    const p = sv;
                    const declared = if (cnav2_publications.PreparedPublication.at(prepared.gps, query_time)) |publication| publication.content.declaration else null;
                    const integrity = if (declared) |c| c.integrity else null;
                    const flags: ?gps_records.CnavFlags = if (f == .cnav) cnav_common_content.cnavFlags(p, integrity, sat.prn()) else null;
                    const isf: ?bool = if (f == .cnav2) cnav_common_content.cnav2Isf(p, integrity) else if (flags) |v| v.integrity_status else null;
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
                },
                .inav, .fnav => {
                    const carried = contentOf(input.flight_plan, sat, f, boundary, &out.reason) orelse return out;
                    const sv = if (f == .inav) &carried.parameters else carried;
                    const selected = display.choice(input.flight_plan.legIdAt(sat, boundary).?);
                    const eph = &sv.eph;
                    out.toe = .of(eph.toe);
                    out.toc = .of(eph.toc);
                    out.orbit = .of(eph.*);
                    if (f == .inav) {
                        out.parameters = .{ .inav = .{
                            .sisaIndex = sv.sisa_index,
                            .iodNavIndex = sv.iod_nav,
                            .e1bHealthIndex = sv.e1b_hs,
                            .e5bHealthIndex = sv.e5b_hs,
                            .e1bDataInvalid = sv.e1b_dvs,
                            .e5bDataInvalid = sv.e5b_dvs,
                            .bgdE1e5aS = selected.group_delay.get(.bgd_e1e5a),
                            .bgdE1e5bS = selected.group_delay.get(.bgd_e1e5b),
                        } };
                    } else {
                        out.parameters = .{ .fnav = .{
                            .sisaIndex = sv.sisa_index,
                            .iodNavIndex = sv.iod_nav,
                            .e5aHealthIndex = sv.e5a_hs,
                            .e5aDataInvalid = sv.e5a_dvs,
                            .clockAvailable = sv.clock_fits,
                            .bgdE1e5aS = selected.group_delay.get(.bgd_e1e5a),
                        } };
                    }
                },
                .d1d2 => {
                    _ = contentOf(input.flight_plan, sat, f, boundary, &out.reason) orelse return out;
                    const selected = display.choice(input.flight_plan.legIdAt(sat, boundary).?);
                    var attributes: navigation_reference.Attributes = .{};
                    const reference = selected.input(display.ephemerides, &attributes).kepler;
                    const parameters = for (selected.messages) |choice| {
                        if (choice == .d1d2) break switch (choice.d1d2) {
                            .original => reference.record.parameters(),
                            .fitted => |fitted| fitted,
                            .unfit => unreachable,
                        };
                    } else unreachable;
                    const x = d1d2_ephemeris.metadata(reference, &parameters).at(query_time);
                    out.toe = .of(parameters.toe);
                    out.toc = .of(parameters.toc);
                    out.orbit = .of(parameters);
                    out.parameters = .{ .d1d2 = .{
                        .format = if (bds_records.isGeo(sat.prn())) .d2 else .d1,
                        .satH1 = x.sat_h1,
                        .uraIndex = x.urai,
                        .aodcIndex = x.aodc,
                        .aodeIndex = x.aode,
                        .tgdB1iS = x.tgd1,
                        .tgdB2iS = x.tgd2,
                    } };
                },
                .bcnav1, .bcnav2, .bcnav3 => {
                    _ = contentOf(input.flight_plan, sat, f, boundary, &out.reason) orelse return out;
                    const selected = display.choice(input.flight_plan.legIdAt(sat, boundary).?);
                    var attributes: navigation_reference.Attributes = .{};
                    const reference = selected.input(display.ephemerides, &attributes).kepler;
                    const sv = bcnav_content.Candidate.fromReference(reference, @field(records.NavSource, @tagName(f)));
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
                    const carried = contentOf(input.flight_plan, sat, f, boundary, &out.reason) orelse return out;
                    const eph = &carried.parameters;
                    const binding = input.flight_plan.bindingAt(sat, boundary).?;
                    const selected = display.choice(input.flight_plan.legIdAt(sat, boundary).?);
                    const record = &display.ephemerides.glonass[selected.reference.glonass];
                    out.toe = .of(eph.tb);
                    out.toc = out.toe;
                    out.glonassOrbit = .{
                        .position_ecef_m = eph.pos,
                        .velocity_ecef_m_per_s = eph.vel,
                        .acceleration_ecef_m_per_s2 = eph.acc,
                        .gamma_n_s_per_s = eph.gamma_n,
                        .tau_n_s = eph.tau_n,
                    };
                    out.parameters = .{ .gnav = .{
                        .health = eph.health,
                        .almanacHealth = record.almanac_health,
                        .ftIndex = record.ft,
                        .enIndex = eph.en,
                        .pIndex = record.p,
                        .preparedP1Index = eph.p1,
                        .p4 = record.p4,
                        .mIndex = record.m,
                        .frequencyChannel = binding.freq.?.k,
                        .deltaTauNS = selected.group_delay.get(.delta_tau_n),
                    } };
                },
                .cnav_has, .ppp_b2b => {
                    out.availability = .not_applicable;
                    out.reason = .service_only;
                    return out;
                },
            }
        },
    }
    out.availability = .available;
    out.reason = null;
    return out;
}

fn gpsText(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (input) |c| {
        if (c == text.degree) {
            out.writer.writeAll("°") catch return error.OutOfMemory;
        } else {
            out.writer.writeByte(c) catch return error.OutOfMemory;
        }
    }
    return out.written();
}

fn gpsPublication(arena: std.mem.Allocator, src: *const gps_publication.Declaration, prn: u8, t: GpsTime, family: NavFamily) !GpsPublication {
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

fn publications(arena: std.mem.Allocator, start: GpsTime, prepared: *const model_publications.Prepared, sat: SatId, family: NavFamily, t: GpsTime) !Publication {
    var out: Publication = .{ .availability = .unavailable, .reason = .no_active_publication };
    switch (family) {
        .lnav, .cnav, .cnav2 => {
            const p = cnav2_publications.PreparedPublication.at(prepared.gps, t) orelse return out;
            out.validity = .of(start, p.from, p.until);
            out.gps = try gpsPublication(arena, p.content.declaration, sat.prn(), t, family);
        },
        .inav => {
            const p = inav_ism.PreparedPublication.at(prepared.inav, t) orelse return out;
            const declaration = p.content.declaration;
            out.validity = .of(start, p.from, p.until);
            var content: InavPublication = .{ .kind = std.meta.activeTag(declaration.*) };
            switch (declaration.*) {
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
                out.contentValidity = .of(start, v.from, v.until);
                if (!p.content.available(t)) {
                    out.reason = if (t.lessThan(v.from)) .publication_not_yet_valid else .publication_expired;
                    return out;
                }
            }
        },
        .d1d2 => {
            if (!bds_records.isGeo(sat.prn())) return .{};
            const p = augmentation.PreparedPublication.at(prepared.d2, t) orelse return out;
            out.validity = .of(start, p.from, p.until);
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

fn servicePublication(prepared: *const model_publications.Prepared, sat: SatId, family: NavFamily, t: GpsTime) bool {
    return switch (family) {
        .d1d2 => bds_records.isGeo(sat.prn()) and augmentation.PreparedPublication.at(prepared.d2, t) != null,
        .cnav, .cnav2 => if (cnav2_publications.PreparedPublication.at(prepared.gps, t)) |p| p.content.declaration.differential != null else false,
        else => false,
    };
}

/// The family's prepared content for the satellite's leg at the message boundary.
fn contentOf(flight_plan: *const FlightPlan, sat: SatId, comptime family: NavFamily, boundary: GpsTime, reason: *?Reason) ?*const @FieldType(@FieldType(message_content.Content, @tagName(family)), "carried") {
    const content = flight_plan.contentAt(sat, family, boundary) orelse return null;
    return switch (@field(content, @tagName(family))) {
        .carried => |*carried| carried,
        .unfit => |unfit| {
            reason.* = switch (unfit) {
                .record => .no_navigation_record,
                .field, .health, .fit => .unrepresentable_parameters,
            };
            return null;
        },
    };
}
