const core = @import("../core.zig");
const System = core.types.System;
const GpsTime = core.time.GpsTime;
const ClockPoly = core.clock.Poly;

pub const Message = enum { header, lnav, cnvx, d1d2, ifnv, fdma };
pub const OffsetKind = enum { gput, gaut, bdut, glut, gagp, glgp, bdgp, bdga, bdgl };

pub const TimeOffset = struct {
    kind: OffsetKind,
    source: ?System,
    message: Message,
    reference: ?GpsTime,
    transmitted: ?GpsTime,
    a0: f64,
    a1: f64,
    a2: f64,

    pub fn scaleOffset(self: TimeOffset, t: GpsTime) ?ClockPoly {
        const sign: f64 = switch (self.kind) {
            .gagp, .bdgp => 1,
            .glgp => -1,
            else => return null,
        };
        const reference = self.reference orelse blk: {
            if (self.a1 != 0 or self.a2 != 0) return null;
            break :blk t;
        };
        return .{ .toc = reference, .af0 = sign * self.a0, .af1 = sign * self.a1, .af2 = sign * self.a2 };
    }
};

pub fn gpsOffsetKind(system: System) ?OffsetKind {
    return switch (system) {
        .gps => null,
        .gal => .gagp,
        .bds => .bdgp,
        .glo => .glgp,
    };
}

pub const Dut1Kind = enum { ut1_utc, ut1_gpst };

pub fn dut1KindOf(dut1: f64) ?Dut1Kind {
    if (@abs(dut1) < 1) return .ut1_utc;
    return if (dut1 < -1) .ut1_gpst else null;
}

pub const Eop = struct {
    source: System,
    message: Message,
    reference: GpsTime,
    transmitted: GpsTime,
    xp_arcsec: f64,
    xp_rate_arcsec_day: f64,
    xp_acc_arcsec_day2: f64,
    yp_arcsec: f64,
    yp_rate_arcsec_day: f64,
    yp_acc_arcsec_day2: f64,
    dut1: f64,
    dut1_kind: ?Dut1Kind,
    dut1_rate_s_day: f64,
    dut1_acc_s_day2: f64,

    pub fn ut1MinusGps(self: Eop, t: GpsTime, gps_minus_utc: f64) ?f64 {
        const at_reference = switch (self.dut1_kind orelse return null) {
            .ut1_utc => self.dut1 - gps_minus_utc,
            .ut1_gpst => self.dut1,
        };
        const days = t.secondsSince(self.reference) / core.time.s_per_day;
        return at_reference + (self.dut1_rate_s_day + 0.5 * self.dut1_acc_s_day2 * days) * days;
    }

    pub fn ut1Rate(self: Eop, t: GpsTime) f64 {
        return self.dut1_rate_s_day + self.dut1_acc_s_day2 * t.secondsSince(self.reference) / core.time.s_per_day;
    }
};

pub const max_transmission_offset_ms: i64 = 4 * core.time.ms_per_week;

pub const reference_step_ms = 16_000;

pub const LeapSecondSchedule = struct {
    delta_tls: i8,
    wn_lsf: u16,
    dn: u8,
    delta_tlsf: i8,

    pub fn eventAt(self: LeapSecondSchedule) GpsTime {
        return .fromWeekMs(self.wn_lsf, @as(i64, self.dn) * core.time.ms_per_day + @as(i64, self.delta_tlsf) * core.time.ms_per_second, 0);
    }

    pub fn of(leap: core.civil.Leap) ?LeapSecondSchedule {
        const change = leap.event orelse leap.lastInsertion() orelse return null;
        const day = @divFloor(change.at_ms - @as(i64, change.count) * core.time.ms_per_second, core.time.ms_per_day) - 1;
        return .{
            .delta_tls = leap.count,
            .wn_lsf = @intCast(@mod(@divFloor(day, 7), core.time.week_modulus_16)),
            .dn = @intCast(@mod(day, 7) + 1),
            .delta_tlsf = change.count,
        };
    }
};

pub const LeapDeclaration = struct {
    delta_tls: i8,
    announced: ?Announced = null,

    const Announced = struct { wn_lsf: u16, dn: u8, delta_tlsf: i8 };

    pub fn schedule(self: LeapDeclaration) ?LeapSecondSchedule {
        const a = self.announced orelse return null;
        return .{ .delta_tls = self.delta_tls, .wn_lsf = a.wn_lsf, .dn = a.dn, .delta_tlsf = a.delta_tlsf };
    }

    pub fn misfit(self: LeapDeclaration) ?[:0]const u8 {
        const a = self.announced orelse return null;
        if (a.dn < 1 or a.dn > 7) return "dn";
        if (@abs(@as(i16, a.delta_tlsf) - self.delta_tls) > 1) return "delta_tlsf";
        return null;
    }
};

pub const LeapError = error{ LeapCountNegative, LeapCountDisagrees };

pub fn leapSchedule(d: LeapDeclaration, start: GpsTime) LeapError!core.civil.Leap {
    const insertions = core.civil.Leap.insertionsAt(start.ms);
    if (d.delta_tls < 0) return error.LeapCountNegative;
    if (insertions < core.civil.Leap.table.table_insertions and d.delta_tls != insertions) return error.LeapCountDisagrees;
    const announced = if (d.misfit() == null) d.schedule() else null;
    const event: ?core.civil.Leap.Change = if (announced) |s|
        .{ .at_ms = s.eventAt().ms, .count = s.delta_tlsf }
    else
        null;
    return .{ .table_insertions = insertions, .count = d.delta_tls, .event = event };
}

pub const UtcParams = struct {
    a0: f64,
    a1: f64,
    a2: f64,
    tot_s: u32,
    wn_t: u16,
    leap: ?LeapSecondSchedule,
};
