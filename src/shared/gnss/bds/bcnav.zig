const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const records = @import("../records.zig");
const Kepler = @import("../reference.zig").Kepler;
const auxiliary = @import("../auxiliary.zig");
const bds_records = @import("records.zig");
const ephemeris = @import("ephemeris_fields.zig");
const almanac = @import("almanac_fields.zig");
const iono = @import("iono_fields.zig");
const time_parameters = @import("time_parameters.zig");
const types = @import("../../core.zig").types;

const Flags = bds_records.BcnavSignalFlags;

pub const Content = @import("../content.zig").Carriage(Sv);

pub const Inputs = struct {
    eph: [63]?*const Content,
    almanacs: []const records.KeplerAlmanac,
    bdgim: ?[9]f64,
    utc: ?auxiliary.UtcParams,
    eop: ?auxiliary.Eop = null,
    offsets: [3]?auxiliary.TimeOffset = @splat(null),
    t: time.GpsTime,
};

const unflagged: Flags = .{ .dif = false, .sif = false, .aif = true };

pub const Sv = struct {
    ephemeris: ephemeris.Source,
    // A reference that states no B-CNAV accuracy, as one converted from D1/D2, sends the last index of each, with AIF
    // set: an unknown accuracy is never sent as the best one.
    sismai: u4 = 15,
    sisai_oe: u5 = 31,
    sisai_ocb: u5 = 31,
    sisai_oc1: u3 = 7,
    sisai_oc2: u3 = 7,
    b1c: Flags = unflagged,
    b2a: Flags = unflagged,
    b2b: Flags = unflagged,
    hs_b1c: bool = false,
    hs_b2a: bool = false,
    hs_b2b: bool = false,
    tgd_b1cp: f64,
    isc_b1cd: f64,
    tgd_b2ap: f64,
    isc_b2ad: f64,
    tgd_b2bi: f64,

    fn fromReference(e: Kepler, source: records.NavSource) Sv {
        const tgd_b1cp = e.delay(.b1c, .pilot) orelse 0;
        const tgd_b2ap = e.delay(.b2a, .pilot) orelse 0;
        var sv: Sv = .{
            .ephemeris = ephemeris.Source.fromReference(e, source),
            .tgd_b1cp = tgd_b1cp,
            .isc_b1cd = (e.delay(.b1c, .data) orelse 0) - tgd_b1cp,
            .tgd_b2ap = tgd_b2ap,
            .isc_b2ad = (e.delay(.b2a, .data) orelse 0) - tgd_b2ap,
            .tgd_b2bi = e.delay(.b2b, .data) orelse 0,
        };
        switch (e.attribute(source) orelse e.record.extra) {
            .bcnav1, .bcnav2, .bcnav3 => |x| {
                sv.sismai = x.sismai;
                sv.sisai_oe = x.sisai_oe;
                sv.sisai_ocb = x.sisai_ocb;
                sv.sisai_oc1 = x.sisai_oc1;
                sv.sisai_oc2 = x.sisai_oc2;
                sv.b1c = x.b1c orelse unflagged;
                sv.b2a = x.b2a orelse unflagged;
                sv.b2b = x.b2b orelse unflagged;
                sv.hs_b1c = x.hs_b1c;
                sv.hs_b2a = x.hs_b2a;
                sv.hs_b2b = x.hs_b2b;
            },
            .d1d2 => |x| {
                sv.hs_b1c = x.sat_h1;
                sv.hs_b2a = x.sat_h1;
                sv.hs_b2b = x.sat_h1;
            },
            else => {},
        }
        return sv;
    }
};

/// A B-CNAV family's content for a leg: the reference as its messages carry it, or the first of their fields it does
/// not fit.
pub fn prepare(e: Kepler, source: records.NavSource) Content {
    const sv = Sv.fromReference(e, source);
    if (misfit(&sv, source)) |name| return .{ .unfit = .{ .field = name } };
    return .{ .carried = sv };
}

pub fn valid(sv: *const Sv, sat: types.SatId, source: records.NavSource) bool {
    return sv.ephemeris.eph.sat == sat and misfit(sv, source) == null and sv.ephemeris.eph.misfit() == null;
}

fn misfit(sv: *const Sv, source: records.NavSource) ?[:0]const u8 {
    if (sv.ephemeris.misfit()) |name| return name;
    return switch (source) {
        .bcnav1 => @import("bcnav1/content.zig").misfit(sv),
        .bcnav2 => @import("bcnav2/content.zig").misfit(sv),
        .bcnav3 => @import("bcnav3/content.zig").misfit(sv),
        else => unreachable,
    };
}

const S = field.Field(Sv);

fn top(s: *const Sv) i64 {
    return s.ephemeris.top.inScale(.bds).ms / records.epoch_step_ms;
}

pub const sisai_oe = [_]S{.{ .name = "sisai_oe", .width = 5, .src = .{ .field = "sisai_oe" } }};

pub const sisai_oc = [_]S{
    .{ .name = "top", .width = 11, .src = .{ .computed_int = &top } },
    .{ .name = "sisai_ocb", .width = 5, .src = .{ .field = "sisai_ocb" } },
    .{ .name = "sisai_oc1", .width = 3, .src = .{ .field = "sisai_oc1" } },
    .{ .name = "sisai_oc2", .width = 3, .src = .{ .field = "sisai_oc2" } },
};

pub const Data = struct {
    sv: [63]?Sv,
    alm: [63]?almanac.Slot,
    almanac_reference: almanac.Reference,
    bdgim: iono.Coefficients,
    utc: ?time_parameters.Utc,
    eop: ?time_parameters.Eop,
    offsets: [3]?time_parameters.Bgto,

    pub fn build(data: *Data, comptime source: records.NavSource, in: Inputs) void {
        comptime {
            if (source != .bcnav1 and source != .bcnav2 and source != .bcnav3) @compileError("B-CNAV inputs require a B-CNAV message source");
        }
        data.* = .{
            .sv = @splat(null),
            .alm = @splat(null),
            .almanac_reference = undefined,
            .bdgim = in.bdgim orelse @splat(0),
            .utc = time_parameters.utcFromRecord(in.utc),
            .eop = time_parameters.eopFromRecord(in.eop),
            .offsets = @splat(null),
        };
        for (in.eph, &data.sv) |entry, *sv| if (entry) |c| if (c.value()) |carried| {
            sv.* = carried.*;
        };
        var reference: ?time.GpsTime = null;
        for (in.almanacs) |a| {
            if (!a.toa.eql(reference orelse a.toa)) continue;
            const entry = almanac.Slot.fromAlmanac(a) orelse continue;
            data.alm[a.sat.prn() - 1] = entry;
            reference = a.toa;
        }
        data.almanac_reference = almanac.Reference.fromTime(reference orelse in.t, .bds);
        for (in.offsets, 0..) |entry, i| data.offsets[i] = time_parameters.bgtoFromRecord(entry, @intCast(i + 1));
    }

    pub fn hasRecord(self: *const Data, prn: u8) bool {
        return self.sv[prn - 1] != null;
    }

    pub fn packet(self: *const Data, prn: u7) almanac.Packet {
        return .{ .slot = if (prn == 0) null else self.alm[prn - 1], .reference = self.almanac_reference };
    }

    pub fn bgto(self: *const Data, start: u2) time_parameters.Bgto {
        for (0..3) |i| if (self.offsets[(start + i) % 3]) |offset| return offset;
        return .{};
    }
};
