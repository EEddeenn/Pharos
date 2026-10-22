const std = @import("std");
const field = @import("base/binary/field");
const bdgim_fields = @import("domain/messages/bds/fields/ionosphere");
const nequick_fields = @import("domain/messages/galileo/fields/ionosphere");
const clock = @import("domain/time/clock");
const ionosphere_config = @import("simulation/model/ionosphere");
const gnss_types = @import("domain/gnss_types");
const auxiliary = @import("domain/navigation/system_data");
const lnav = @import("domain/messages/gps/lnav/set");
const cnav = @import("domain/messages/gps/cnav_common/set");
const galileo = @import("domain/messages/galileo/system");
const d1d2 = @import("domain/messages/bds/d1d2/set");
const bcnav = @import("domain/messages/bds/bcnav/set");
const gnav = @import("domain/messages/glonass/gnav/system");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const gps_time = @import("domain/messages/gps/fields/time");
const galileo_time = @import("domain/messages/galileo/fields/time");
const bds_time = @import("domain/messages/bds/fields/time");
const d1d2_pages = @import("domain/messages/bds/d1d2/pages");
const klobuchar = @import("domain/messages/fields/klobuchar");
const GpsTime = time.GpsTime;

const ClockPoly = clock.Poly;
const Broadcast = ionosphere_config.Broadcast;

pub const ScaleChoice = union(enum) { record: u32, zero };
pub const DerivedUtc = struct { donor: gnss_types.System, utc: u32, donor_scale: ScaleChoice, bds_scale: ScaleChoice };
pub const UtcChoice = union(enum) { record: u32, derived: DerivedUtc };
pub const EopChoice = union(enum) { record: u32, zero };

pub const GgtoChoice = struct { record: u32, anchor: gps_time.GgtoAnchor };

pub const GpsChoice = struct {
    lnav_utc: ?UtcChoice = null,
    cnav_utc: ?UtcChoice = null,
    eop: ?EopChoice = null,
    ggto: [2]?GgtoChoice = @splat(null),
};
pub const GalileoChoice = struct { utc: ?UtcChoice = null, ggto: ?u32 = null };
pub const BdsChoice = struct {
    d1d2_utc: ?UtcChoice = null,
    bcnav_utc: ?UtcChoice = null,
    eop: ?EopChoice = null,
    offsets: [3]?u32 = @splat(null),
};
pub const GlonassChoice = struct { utc: ?u32 = null, gps: ?u32 = null, eop: ?EopChoice = null };

pub const Stored = struct {
    records: auxiliary.SystemRecords,
    scales: std.EnumArray(gnss_types.System, ScaleChoice) = .initFill(.zero),
    gps: []const Entry(GpsChoice) = &.{},
    galileo: []const Entry(GalileoChoice) = &.{},
    bds: []const Entry(BdsChoice) = &.{},
    glonass: []const Entry(GlonassChoice) = &.{},
};

pub const Gps = struct { lnav: lnav.System, cnav: cnav.System };
pub const Bds = struct { d1d2: ?d1d2.System, bcnav: bcnav.System };

pub const Systems = struct {
    start: GpsTime,
    gps: []const Entry(Gps) = &.{},
    galileo: []const Entry(galileo.System) = &.{},
    bds: []const Entry(Bds) = &.{},
    glonass: []const Entry(?gnav.System) = &.{},

    pub fn at(self: *const Systems, comptime system: gnss_types.System, t: GpsTime) ?*const Value(system) {
        const entries = @field(self, switch (system) {
            .gps => "gps",
            .gal => "galileo",
            .bds => "bds",
            .glo => "glonass",
        });
        if (t.lessThan(self.start)) return null;
        const elapsed: u64 = @intCast(t.ms - self.start.ms);
        var first: usize = 0;
        var end = entries.len;
        while (first < end) {
            const mid = first + (end - first) / 2;
            if (entries[mid].from_ms <= elapsed) first = mid + 1 else end = mid;
        }
        return if (first == 0) null else &entries[first - 1].value;
    }
};

pub fn Entry(comptime T: type) type {
    return struct { from_ms: u64, value: T };
}

pub fn Value(comptime system: gnss_types.System) type {
    return switch (system) {
        .gps => Gps,
        .gal => galileo.System,
        .bds => Bds,
        .glo => ?gnav.System,
    };
}

pub fn scalePolynomial(records: *const auxiliary.SystemRecords, choice: ScaleChoice, at: GpsTime) ClockPoly {
    return switch (choice) {
        .record => |index| records.time_offsets[index].scaleOffset(at).?,
        .zero => .{ .toc = at, .af0 = 0, .af1 = 0, .af2 = 0 },
    };
}

pub fn utcParameters(records: *const auxiliary.SystemRecords, choice: UtcChoice, at: GpsTime, system: gnss_types.System, leap: civil.Leap) auxiliary.UtcParams {
    const polynomial: ClockPoly = switch (choice) {
        .record => |index| blk: {
            const record = records.time_offsets[index];
            break :blk .{ .toc = record.reference.?, .af0 = record.a0, .af1 = record.a1, .af2 = record.a2 };
        },
        .derived => |selected| blk: {
            const bdt = at.inScale(.bds);
            const reference = GpsTime.fromScaleWeekMs(.bds, bdt.period, bdt.ms / auxiliary.reference_step_ms * auxiliary.reference_step_ms, 0);
            const donor = records.time_offsets[selected.utc];
            const utc: ClockPoly = .{ .toc = donor.reference orelse reference, .af0 = donor.a0, .af1 = donor.a1, .af2 = donor.a2 };
            const origin = scalePolynomial(records, selected.donor_scale, at);
            const target = scalePolynomial(records, selected.bds_scale, at);
            break :blk .{ .toc = reference, .af0 = utc.bias(reference) - origin.bias(reference) + target.bias(reference), .af1 = utc.drift(reference) - origin.drift(reference) + target.drift(reference), .af2 = utc.af2 - origin.af2 + target.af2 };
        },
    };
    const stamp = polynomial.toc.inScale(if (system == .bds) .bds else .gps);
    return .{ .a0 = polynomial.af0, .a1 = polynomial.af1, .a2 = polynomial.af2, .tot_s = stamp.ms / 1000, .wn_t = @intCast(@mod(stamp.period, time.week_modulus_16)), .leap = auxiliary.LeapSecondSchedule.of(leap) };
}

pub fn eopRecord(records: *const auxiliary.SystemRecords, choice: EopChoice, system: gnss_types.System, reference: GpsTime) auxiliary.Eop {
    return switch (choice) {
        .record => |index| records.eops[index],
        .zero => .{ .source = system, .message = if (system == .gps) .cnvx else if (system == .glo) .fdma else .d1d2, .reference = reference, .transmitted = reference, .xp_arcsec = 0, .xp_rate_arcsec_day = 0, .xp_acc_arcsec_day2 = 0, .yp_arcsec = 0, .yp_rate_arcsec_day = 0, .yp_acc_arcsec_day2 = 0, .dut1 = .{ .ut1_utc = 0 }, .dut1_rate_s_day = 0, .dut1_acc_s_day2 = 0 },
    };
}

pub fn projectGps(records: *const auxiliary.SystemRecords, choice: GpsChoice, at: GpsTime, leap: civil.Leap, broadcast: *const Broadcast) Gps {
    const utc = if (choice.cnav_utc) |selected| utcParameters(records, selected, at, .gps, leap) else null;
    var out: Gps = .{
        .lnav = .{ .page18 = if (choice.lnav_utc) |selected| lnav.projectPage18(utcParameters(records, selected, at, .gps, leap), broadcast.klobuchar) else null },
        .cnav = .{ .klobuchar = field.project(klobuchar.Coefficients, &klobuchar.coefficients, &klobuchar.Coefficients.of(broadcast.klobuchar)), .utc = if (utc) |value| gps_time.projectUtc(value) else null, .eop = null, .ggto = .{} },
    };
    if (choice.eop) |selected| {
        const value = utc.?;
        const reference = GpsTime.fromWeekMs(value.wn_t, @as(i64, value.tot_s) * 1000, 0);
        out.cnav.eop = gps_time.projectEop(eopRecord(records, selected, .gps, reference), value);
    }
    for (choice.ggto) |selected| if (selected) |entry| {
        const record = records.time_offsets[entry.record];
        const reference = switch (entry.anchor) {
            .record_reference => record.reference.?,
            .week_start => GpsTime.fromWeekMs(at.week(), 0, 0),
        };
        out.cnav.ggto.list[out.cnav.ggto.len] = gps_time.projectGgto(record, reference);
        out.cnav.ggto.len += 1;
    };
    return out;
}

pub fn projectGalileo(records: *const auxiliary.SystemRecords, choice: GalileoChoice, at: GpsTime, leap: civil.Leap, broadcast: *const Broadcast) galileo.System {
    return .{ .iono = field.project(nequick_fields.Coefficients, &nequick_fields.rows, &(broadcast.nequick orelse .zero)), .utc = if (choice.utc) |selected| galileo_time.projectUtc(utcParameters(records, selected, at, .gal, leap)) else null, .ggto = if (choice.ggto) |index| galileo_time.projectGgto(records.time_offsets[index]) else galileo_time.unavailable_ggto };
}

pub fn projectBds(records: *const auxiliary.SystemRecords, choice: BdsChoice, at: GpsTime, leap: civil.Leap, broadcast: *const Broadcast) Bds {
    const bdt = at.inScale(.bds);
    const reference = GpsTime.fromScaleWeekMs(.bds, bdt.period, bdt.ms / auxiliary.reference_step_ms * auxiliary.reference_step_ms, 0);
    var out: Bds = .{
        .d1d2 = if (choice.d1d2_utc) |selected| .{ .utc = d1d2_pages.projectUtc(utcParameters(records, selected, at, .bds, leap), at), .klobuchar = field.project(klobuchar.Coefficients, &klobuchar.coefficients, &klobuchar.Coefficients.of(broadcast.bds_klobuchar)), .epoch = at } else null,
        .bcnav = .{ .bdgim = field.project(bdgim_fields.Coefficients, &bdgim_fields.bdgim, &(broadcast.bdgim orelse @splat(0))), .utc = if (choice.bcnav_utc) |selected| bds_time.projectUtc(utcParameters(records, selected, at, .bds, leap)) else null, .eop = if (choice.eop) |selected| bds_time.projectEop(eopRecord(records, selected, .bds, reference)) else null, .offsets = @splat(null) },
    };
    for (choice.offsets, 0..) |selected, index| if (selected) |record| {
        out.bcnav.offsets[index] = bds_time.projectBgto(records.time_offsets[record], @intCast(index + 1));
    };
    return out;
}

pub fn projectGlonass(records: *const auxiliary.SystemRecords, choice: GlonassChoice, day: gnav.Day, at: GpsTime, leap: civil.Leap) ?gnav.System {
    const utc = records.time_offsets[choice.utc orelse return null];
    const gps = records.time_offsets[choice.gps orelse return null];
    const selected = choice.eop orelse return null;
    const reference_day = day;
    const reference = GpsTime.fromGlonass(leap, .{ .n4 = reference_day.n4, .nt = reference_day.na, .ms_of_day = 0, .sub_ms = 0 });
    return .{ .scale = gnav.projectScale(utc, gps, reference_day), .string14 = gnav.projectString14(eopRecord(records, selected, .glo, reference), reference_day, at, leap), .leap = leap };
}
