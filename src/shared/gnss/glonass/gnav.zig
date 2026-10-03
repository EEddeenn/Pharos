const types = @import("../../core.zig").types;
const time = @import("../../core.zig").time;
const civil = @import("../../core.zig").civil;
const field = @import("../../codec.zig").field;
const frame = @import("../../codec.zig").frame;
const bitwriter = @import("../../codec.zig").bitwriter;
const auxiliary = @import("../auxiliary.zig");
const records = @import("records.zig");
const tables = @import("gnav/tables.zig");
const string = @import("gnav/string.zig");

pub const misfit = tables.misfit;
pub const scaleMisfit = tables.scaleMisfit;
pub const almanac_even = tables.almanac_even;
pub const almanac_odd = tables.almanac_odd;

const Eph = records.GlonassEphemeris;
const Alm = records.GlonassAlmanac;
const GpsTime = time.GpsTime;

pub const frame_ms = 2000;
pub const bits_per_frame = string.symbols_per_string;
const strings_per_frame = 15;
const frames_per_day = 2880;
const strings_per_day = strings_per_frame * frames_per_day;
pub const Frame = string.Frame;
const Error = field.Error;

const Slot = struct {
    string: u4,
    frame_in_superframe: u3,
    tk_h: u5,
    tk_m: u6,
    tk_half: u1,
};

const frames_per_hour = 120;
const b1_max_s = 0.9;
const b2_min_s_per_day = -4.5e-3;
const b2_max_s_per_day = 3.5e-3;

fn slot(index: i64) Slot {
    const in_day = @mod(index, strings_per_day);
    const fr = @divFloor(in_day, strings_per_frame);
    return .{
        .string = @intCast(@mod(in_day, strings_per_frame) + 1),
        .frame_in_superframe = @intCast(@mod(fr, 5)),
        .tk_h = @intCast(@divFloor(fr, frames_per_hour)),
        .tk_m = @intCast(@divFloor(@mod(fr, frames_per_hour), 2)),
        .tk_half = @intCast(@mod(fr, 2)),
    };
}

const slots = types.System.glo.capacity();

pub const Set = struct {
    eph: [slots]?*const Eph,
    p1: [slots]?u2,
    first_string: [slots]i64,
    alm: [slots]?Alm,
    scale: ?tables.TimeScale,
    string14: ?tables.String14,
    leap: civil.Leap,

    pub const Inputs = struct {
        eph: [slots]?*const Eph,
        p1: [slots]?u2 = @splat(null),
        almanacs: []const Alm,
        time_utc: ?auxiliary.TimeOffset,
        time_gps: ?auxiliary.TimeOffset,
        eop: ?auxiliary.Eop,
        t: GpsTime,
        leap: civil.Leap,
    };

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.* = .{
            .eph = in.eph,
            .p1 = in.p1,
            .first_string = @splat(0),
            .alm = @splat(null),
            .scale = null,
            .string14 = null,
            .leap = in.leap,
        };
        for (in.eph, &set.first_string) |entry, *first| {
            if (entry) |e| first.* = firstString(e, in.leap);
        }

        var day: ?Day = null;
        for (in.almanacs) |a| {
            if (!field.fits(Alm, &tables.almanac_even, &a) or !field.fits(Alm, &tables.almanac_odd, &a)) continue;
            if (day) |d| if (a.n4 != d.n4 or a.na != d.na) continue;
            set.alm[a.sat.prn() - 1] = a;
            if (day == null) day = .{ .n4 = a.n4, .na = a.na };
        }

        if (day == null) {
            if (in.time_utc) |utc| {
                if (utc.reference) |ref| {
                    day = dayOf(ref, in.leap);
                }
            }
        }

        if (day orelse dayOf(in.t, in.leap)) |d| {
            set.scale = blk: {
                const utc = in.time_utc orelse break :blk null;
                const gps = in.time_gps orelse break :blk null;
                if (utc.a1 != 0 or utc.a2 != 0 or gps.a1 != 0 or gps.a2 != 0) break :blk null;
                break :blk .{ .na = @intCast(d.na), .n4 = d.n4, .tau_c = -utc.a0, .tau_gps = gps.a0 };
            };
            set.string14 = string14(in.eop, d, in.t, in.leap);
        }
        try set.validate();
    }

    fn validate(self: *const Set) Error!void {
        const shared_prn: u8 = for (self.eph, 1..) |entry, prn| {
            if (entry != null) break @intCast(prn);
        } else return;

        for (self.eph, 1..) |entry, prn| {
            if (entry == null) continue;
            for (0..4) |i| _ = try self.encodeData(@intCast(prn), @intCast(i));
        }

        for (0..5 * strings_per_frame) |i| {
            const s = slot(@intCast(i));
            if (s.string <= 4) continue;
            if (s.string == 5 and self.scale == null) continue;
            if (s.string == 14 and s.frame_in_superframe == 4 and self.string14 == null) continue;
            _ = try self.encodeData(shared_prn, @intCast(i));
        }
    }

    fn encodeData(self: *const Set, prn: u8, index: i64) Error!u76 {
        var bits: frame.Bits(tables.data_bits) = .{};
        var w = bits.writer();
        const s = slot(index);
        const eph = self.eph[prn - 1].?;
        const moscow = tables.moscow(eph, self.leap);
        const ctx = tables.Ctx{
            .m = s.string,
            .tk_h = s.tk_h,
            .tk_m = s.tk_m,
            .tk_half = s.tk_half,
            .p1 = if (index == self.first_string[prn - 1]) self.p1[prn - 1] orelse eph.p1 else 0,
            .p3 = @intFromBool(s.frame_in_superframe < 4),
            .ln = @intFromBool(!eph.health),
            .tb = moscow.tb,
            .p2 = moscow.p2,
            .nt = moscow.nt,
        };
        switch (s.string) {
            1 => try field.encode(Eph, &tables.string1, eph, ctx, &w),
            2 => try field.encode(Eph, &tables.string2, eph, ctx, &w),
            3 => try field.encode(Eph, &tables.string3, eph, ctx, &w),
            4 => try field.encode(Eph, &tables.string4, eph, ctx, &w),
            5 => try field.encode(tables.TimeScale, &tables.string5, &self.scale.?, ctx, &w),
            else => try self.encodeAlmanac(s, ctx, &w),
        }
        var data: u76 = 0;
        for (0..tables.data_bits) |i| data = (data << 1) | bits.get(i);
        return data;
    }

    fn encodeAlmanac(self: *const Set, s: Slot, ctx: tables.Ctx, w: *bitwriter.BitWriter) Error!void {
        const pair: u5 = (s.string - 6) / 2;
        const number: u5 = @as(u5, s.frame_in_superframe) * 5 + pair + 1;
        var almanac_ctx = ctx;
        almanac_ctx.slot = number;
        const even = s.string % 2 == 0;

        if (number <= slots) {
            if (self.alm[number - 1]) |*a| {
                return if (even)
                    field.encode(Alm, &tables.almanac_even, a, almanac_ctx, w)
                else
                    field.encode(Alm, &tables.almanac_odd, a, almanac_ctx, w);
            }
            if (even) return field.encode(field.NoSource, &tables.empty_even, &field.no_source, almanac_ctx, w);
        }

        if (even) return field.encode(tables.String14, &tables.string14, &self.string14.?, almanac_ctx, w);
        try field.encode(field.NoSource, &tables.filler_odd, &field.no_source, almanac_ctx, w);
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.eph[prn - 1] != null and self.scale != null and self.string14 != null;
    }
};

fn firstString(g: *const Eph, leap: civil.Leap) i64 {
    return @divExact(records.adoption(g, leap).baseMs(.glo, leap), frame_ms);
}

const Day = struct { n4: u5, na: u16 };

fn dayOf(t: GpsTime, leap: civil.Leap) ?Day {
    const g = t.toGlonass(leap);
    if (g.n4 < 1 or g.n4 > 31) return null;
    return .{ .n4 = @intCast(g.n4), .na = g.nt };
}

fn string14(eop: ?auxiliary.Eop, day: Day, t: GpsTime, leap: civil.Leap) ?tables.String14 {
    const e = eop orelse return null;
    const start = GpsTime.fromGlonass(leap, .{ .n4 = day.n4, .nt = day.na, .ms_of_day = 0, .sub_ms = 0 });
    const ut1_gps = e.ut1MinusGps(start, @floatFromInt(e.reference.leap(leap).count)) orelse return null;
    const out: tables.String14 = .{
        .b1 = ut1_gps + @as(f64, @floatFromInt(start.leap(leap).count)),
        .b2 = e.ut1Rate(start),
        .kp = switch (civil.quarterEndStep(leap, t.ms)) {
            1 => 0b01,
            -1 => 0b11,
            else => 0b00,
        },
    };
    if (!(@abs(out.b1) <= b1_max_s and out.b2 >= b2_min_s_per_day and out.b2 <= b2_max_s_per_day)) return null;
    if (!field.fits(tables.String14, &tables.string14, &out)) return null;
    return out;
}

pub fn requireData(set: *const Set, prn: u8) error{ MissingTimeOffset, MissingEarthOrientation }!void {
    if (set.eph[prn - 1] == null) return;
    if (set.scale == null) return error.MissingTimeOffset;
    if (set.string14 == null) return error.MissingEarthOrientation;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const data = set.encodeData(prn, index) catch unreachable;
    return string.encode(string.encodeString(data));
}
