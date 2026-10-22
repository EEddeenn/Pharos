const auxiliary = @import("domain/navigation/system_data");
const civil = @import("domain/time/civil");
const field = @import("base/binary/field");
const fields = @import("domain/messages/glonass/gnav/fields");
const GpsTime = @import("domain/time/gps").GpsTime;
const b1_max_s = 0.9;
const b2_min_s_per_day = -4.5e-3;
const b2_max_s_per_day = 3.5e-3;

pub const System = struct { scale: ScaleCodes, string14: String14Codes, leap: civil.Leap };

pub const Day = struct { n4: u5, na: u16 };

pub const ScaleCodes = field.Decoded(fields.TimeScale, &fields.string5);
pub const String14Codes = field.Decoded(fields.String14, &fields.string14);

pub fn dayOf(t: GpsTime, leap: civil.Leap) ?Day {
    const g = t.toGlonass(leap);
    if (g.n4 < 1 or g.n4 > 31) return null;
    return .{ .n4 = @intCast(g.n4), .na = g.nt };
}

pub fn string14(eop: ?auxiliary.Eop, day: Day, t: GpsTime, leap: civil.Leap) ?String14Codes {
    const e = eop orelse return null;
    const out = candidateString14(e, day, t, leap);
    if (!(@abs(out.b1) <= b1_max_s and out.b2 >= b2_min_s_per_day and out.b2 <= b2_max_s_per_day)) return null;
    return switch (field.prepare(fields.String14, &fields.string14, &out)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn projectString14(eop: auxiliary.Eop, day: Day, at: GpsTime, leap: civil.Leap) String14Codes {
    return field.project(fields.String14, &fields.string14, &candidateString14(eop, day, at, leap));
}

pub fn scale(utc: auxiliary.TimeOffset, gps: auxiliary.TimeOffset, day: Day) ?ScaleCodes {
    if (utc.a1 != 0 or utc.a2 != 0 or gps.a1 != 0 or gps.a2 != 0) return null;
    const candidate: fields.TimeScale = .{ .na = @intCast(day.na), .n4 = day.n4, .tau_c = -utc.a0, .tau_gps = gps.a0 };
    return switch (field.prepare(fields.TimeScale, &fields.string5, &candidate)) {
        .codes => |codes| codes,
        .badfield => null,
    };
}

pub fn projectScale(utc: auxiliary.TimeOffset, gps: auxiliary.TimeOffset, day: Day) ScaleCodes {
    const candidate: fields.TimeScale = .{ .na = @intCast(day.na), .n4 = day.n4, .tau_c = -utc.a0, .tau_gps = gps.a0 };
    return field.project(fields.TimeScale, &fields.string5, &candidate);
}

fn candidateString14(e: auxiliary.Eop, day: Day, t: GpsTime, leap: civil.Leap) fields.String14 {
    const start = GpsTime.fromGlonass(leap, .{ .n4 = day.n4, .nt = day.na, .ms_of_day = 0, .sub_ms = 0 });
    const ut1_gps = e.ut1MinusGps(start, @floatFromInt(e.reference.leap(leap).count));
    return .{
        .b1 = ut1_gps + @as(f64, @floatFromInt(start.leap(leap).count)),
        .b2 = e.ut1Rate(start),
        .kp = switch (civil.quarterEndStep(leap, t.ms)) {
            1 => 0b01,
            -1 => 0b11,
            else => 0b00,
        },
    };
}
