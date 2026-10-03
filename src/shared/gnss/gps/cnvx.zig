const time = @import("../../core.zig").time;
const iono = @import("../../core.zig").iono;
const records = @import("../records.zig");
const reference = @import("../reference.zig");
const auxiliary = @import("../auxiliary.zig");
const Component = @import("../../core.zig").types.Component;
const Signal = @import("../../core.zig").types.Signal;
const kepler = @import("../kepler.zig");
const klobuchar_fields = @import("../klobuchar_fields.zig");
const gps_records = @import("records.zig");
const accuracy = @import("accuracy.zig");
const almanac_fields = @import("almanac_fields.zig");
const ephemeris = @import("ephemeris_fields.zig");
const time_parameters = @import("time_parameters.zig");
const messages = @import("messages.zig");
const almanac_reference = @import("../almanac_reference.zig");

const Eph = records.KeplerEphemeris;
const Alm = records.KeplerAlmanac;

pub const Inputs = struct {
    eph: [32]?reference.Kepler,
    almanacs: []const Alm,
    klobuchar: iono.klobuchar.Model,
    utc: ?auxiliary.UtcParams,
    eop: ?auxiliary.Eop = null,
    ggto: [2]?auxiliary.TimeOffset = .{ null, null },
    t: time.GpsTime,
};

const cnav_lead_s = gps_records.CnavExtra.transmission_lead_s;

pub const Unfit = union(enum) { field: [:0]const u8, health: [:0]const u8 };

pub const Sv = struct {
    parameters: ephemeris.Parameters,
    misfit: ?Unfit,

    fn fromRecord(e: *const Eph, source: records.NavSource) Sv {
        return fromReference(.raw(e), source);
    }

    pub fn fromReference(e: reference.Kepler, source: records.NavSource) Sv {
        const extra = e.attribute(source) orelse e.record.extra;
        const alignment = e.record.parameters().alignedToEpochStep();
        const aligned = alignment.parameters;
        const parameters = if (source == .cnav2) aligned.withClockEpoch(aligned.toe) else aligned;
        const start = if (e.record.top != null) aligned.toe.addSeconds(-cnav_lead_s) else aligned.toe.addSeconds(-kepler.window_s);
        const predicted = if (e.record.top) |top| (if (alignment.rebased) aligned.toe else top) else start;
        const t_gd = e.group_delay.get(.tgd_l1ca);
        var sv: ephemeris.Parameters = .{
            .eph = parameters,
            .wn = @intCast(@mod(start.week(), time.week_modulus_13)),
            .top_s = predicted.msOfWeek() / 1000,
            .tgd = t_gd orelse 0,
            .isc_l1ca = iscOf(e, t_gd, .l1ca, .data),
            .isc_l2c = iscOf(e, t_gd, .l2c, .data),
            .isc_l5i5 = iscOf(e, t_gd, .l5, .data),
            .isc_l5q5 = iscOf(e, t_gd, .l5, .pilot),
            .isc_l1cd = iscOf(e, t_gd, .l1c, .data),
            .isc_l1cp = iscOf(e, t_gd, .l1c, .pilot),
            .wn_op = @intCast(@mod(predicted.week(), time.week_modulus_8)),
        };
        switch (extra) {
            .lnav => |x| {
                sv.ura = accuracy.ofLnav(x.ura_index);
                if (source == .cnav2) {
                    sv.l1_health = x.l1cHealth() orelse false;
                } else if (x.carrierHealth()) |bits| {
                    sv.l1_health = bits & 0b100 != 0;
                    sv.l2_health = bits & 0b010 != 0;
                    sv.l5_health = bits & 0b001 != 0;
                }
            },
            .cnav => |x| {
                sv.ura = x.ura;
                sv.l1_health = x.l1_health;
                sv.l2_health = x.l2_health;
                sv.l5_health = x.l5_health;
                sv.flags = x.flags;
            },
            .cnav2 => |x| {
                sv.ura = x.ura;
                sv.l1_health = x.l1_health;
                sv.integrity_status = x.integrity_status;
            },
            else => {},
        }
        const failure: ?Unfit = if (ephemeris.misfit(&sv)) |name|
            .{ .field = name }
        else if (healthGapOf(extra, source)) |signals|
            .{ .health = signals }
        else
            null;
        return .{ .parameters = sv, .misfit = failure };
    }
};

fn healthGapOf(extra: records.SourceExtra, source: records.NavSource) ?[:0]const u8 {
    return switch (source) {
        .cnav => switch (extra) {
            .lnav => |x| if (x.carrierHealth() == null) "L1, L2 and L5" else null,
            .cnav2 => "L1, L2 and L5",
            else => null,
        },
        .cnav2 => switch (extra) {
            .lnav => |x| if (x.l1cHealth() == null) "L1C" else null,
            .cnav => |x| if (!x.l1_health) "L1C" else null,
            else => null,
        },
        else => null,
    };
}

pub fn cnavFlags(sv: *const Sv, declared: ?messages.Integrity, prn: u8) ?gps_records.CnavFlags {
    if (sv.misfit != null) return null;
    if (sv.parameters.flags) |own| return own;
    const d = declared orelse return null;
    return .{ .integrity_status = d.isf == 1, .l2c_phasing = false, .alert = d.alerts(prn) };
}

pub fn cnav2Isf(sv: *const Sv, declared: ?messages.Integrity) ?bool {
    if (sv.misfit != null) return null;
    if (sv.parameters.integrity_status) |own| return own;
    const d = declared orelse return null;
    return d.isf == 1;
}

fn iscOf(e: reference.Kepler, t_gd: ?f64, signal: Signal, component: Component) f64 {
    const t = t_gd orelse return 0;
    return t - (e.delay(signal, component) orelse t);
}

pub fn misfit(e: *const Eph) ?[:0]const u8 {
    const failure = Sv.fromRecord(e, e.source()).misfit orelse return null;
    return switch (failure) {
        .field, .health => |name| name,
    };
}

const Ggtos = struct {
    list: [2]time_parameters.Ggto = undefined,
    len: u2 = 0,

    pub fn at(self: *const Ggtos, ordinal: i64) time_parameters.Ggto {
        if (self.len == 0) return .{};
        return self.list[@intCast(@mod(ordinal, @as(i64, self.len)))];
    }
};

pub const Data = struct {
    sv: [32]?Sv,
    alm: [32]?Alm,
    almanac_reference: almanac_fields.Reference,
    klobuchar: klobuchar_fields.Coefficients,
    utc: ?time_parameters.Utc,
    eop: ?time_parameters.Eop,
    ggto: Ggtos,

    pub fn build(data: *Data, comptime source: records.NavSource, in: Inputs) void {
        comptime {
            if (source != .cnav and source != .cnav2) @compileError("CNAV inputs require a CNAV or CNAV-2 message source");
        }
        const utc = time_parameters.utcBlock(in.utc);
        data.* = .{
            .sv = @splat(null),
            .alm = @splat(null),
            .almanac_reference = undefined,
            .klobuchar = .of(in.klobuchar),
            .utc = utc,
            .eop = if (utc != null) time_parameters.eopBlock(in.eop, in.utc) else null,
            .ggto = .{},
        };
        for (in.ggto) |offset| if (time_parameters.ggtoBlock(offset, in.t)) |block| {
            data.ggto.list[data.ggto.len] = block;
            data.ggto.len += 1;
        };
        for (in.eph, 0..) |entry, i| if (entry) |e| {
            data.sv[i] = Sv.fromReference(e, source);
        };
        var toa: ?time.GpsTime = null;
        for (in.almanacs) |a| {
            if (!almanac_fields.representable(a) or a.toa.sub_ms != 0 or a.toa.msOfWeek() % almanac_reference.toa_step_ms != 0) continue;
            if (!a.toa.eql(toa orelse a.toa)) continue;
            toa = a.toa;
            data.alm[a.sat.prn() - 1] = a;
        }
        data.almanac_reference = almanac_fields.Reference.fromTime(toa orelse in.t, .gps);
    }

    pub fn hasRecord(self: *const Data, prn: u8) bool {
        return self.sv[prn - 1] != null;
    }

    pub fn almanacPrns(self: *const Data) Prns {
        var out: Prns = .{};
        for (&self.alm, 1..) |*entry, number| {
            if (entry.* == null) continue;
            out.list[out.len] = @intCast(number);
            out.len += 1;
        }
        return out;
    }
};

pub const Prns = struct {
    list: [32]u6 = undefined,
    len: u6 = 0,

    pub fn group(self: *const Prns, size: usize, ordinal: i64) []const u6 {
        const groups: i64 = @intCast((self.len + size - 1) / size);
        const first = size * @as(usize, @intCast(@mod(ordinal, groups)));
        return self.list[first..@min(first + size, self.len)];
    }

    pub fn at(self: *const Prns, ordinal: i64) u6 {
        return self.list[@intCast(@mod(ordinal, @as(i64, self.len)))];
    }
};
