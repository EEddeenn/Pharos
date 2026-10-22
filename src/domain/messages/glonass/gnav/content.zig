const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const glonass_records = @import("domain/navigation/records/glonass");
const fields = @import("domain/messages/glonass/gnav/fields");
const carriage = @import("domain/messages/carriage");
const GpsTime = time.GpsTime;
pub const Parameters = struct {
    sat: gnss_types.SatId,
    tb: GpsTime,
    pos: [3]f64,
    vel: [3]f64,
    acc: [3]f64,
    gamma_n: f64,
    tau_n: f64,
    delta_tau_n: f64,
    health: bool,
    ft: u4,
    en: u5,
    p: u2,
    p1: u2,
    p4: bool,
    m: u2,
};

pub const Prepared = struct { parameters: Parameters, first_string: i64 };
pub const Content = carriage.Carriage(Prepared);
pub const Choice = carriage.Choice;
pub const Preparation = struct { choice: Choice, content: Content };

/// GNAV's content for a leg: its fields, with the leg's P1 and Delta tau_n and an unknown F_T stated, or the first of
/// its fields it does not fit.
pub fn prepare(g: *const glonass_records.GlonassEphemeris, p1: u2, delta_tau_n: ?f64, leap: civil.Leap) Preparation {
    const out = parametersOf(g, p1, delta_tau_n);
    if (fields.misfit(&out, leap)) |name| {
        const why: carriage.Unfit = .{ .field = name };
        return .{ .choice = .{ .unfit = why }, .content = .{ .unfit = why } };
    }
    return .{ .choice = .carried, .content = .{ .carried = completed(out, leap) } };
}

pub fn project(g: *const glonass_records.GlonassEphemeris, p1: u2, delta_tau_n: ?f64, leap: civil.Leap, choice: Choice) Content {
    return switch (choice) {
        .carried => .{ .carried = completed(parametersOf(g, p1, delta_tau_n), leap) },
        .unfit => |why| .{ .unfit = why },
    };
}

pub fn misfit(g: *const glonass_records.GlonassEphemeris, leap: civil.Leap) ?[:0]const u8 {
    const e = fromRecord(g);
    return fields.misfit(&e, leap);
}

fn parametersOf(g: *const glonass_records.GlonassEphemeris, p1: u2, delta_tau_n: ?f64) Parameters {
    var out = fromRecord(g);
    out.p1 = p1;
    out.delta_tau_n = delta_tau_n orelse 0;
    return out;
}

fn completed(out: Parameters, leap: civil.Leap) Prepared {
    return .{ .parameters = out, .first_string = @divExact(glonass_records.adoption(out.tb, leap).baseMs(.glo, leap), 2000) };
}

fn fromRecord(g: *const glonass_records.GlonassEphemeris) Parameters {
    return .{
        .sat = g.sat,
        .tb = g.tb,
        .pos = g.pos,
        .vel = g.vel,
        .acc = g.acc,
        .gamma_n = g.gamma_n,
        .tau_n = g.tau_n,
        .delta_tau_n = g.delta_tau_n orelse 0,
        .health = g.health,
        .ft = g.ft orelse fields.unknown_ft,
        .en = g.en,
        .p = g.p orelse 0,
        .p1 = g.p1,
        .p4 = g.p4 orelse false,
        .m = g.m orelse 1,
    };
}
