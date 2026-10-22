const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const records = @import("domain/navigation/records");
const reference = @import("domain/navigation/reference");
const kepler = @import("domain/navigation/orbit/kepler");
const gps_records = @import("domain/navigation/records/gps");
const accuracy = @import("domain/navigation/accuracy/gps");
const ephemeris = @import("domain/messages/gps/fields/ephemeris");
const messages = @import("domain/messages/gps/publication");
const carriage = @import("domain/messages/carriage");
const Component = gnss_types.Component;
const Signal = gnss_types.Signal;
const Eph = records.KeplerEphemeris;
const cnav_lead_s = gps_records.CnavExtra.transmission_lead_s;
pub const Content = carriage.Carriage(ephemeris.Parameters);
pub const Choice = carriage.Choice;
pub const Preparation = struct { choice: Choice, content: Content };
const Failure = union(enum) { field: [:0]const u8, health: [:0]const u8 };

/// CNAV's or CNAV-2's content for a leg: the reference as the family's messages carry it, or why they cannot, in which
/// case the family sends its unavailable form.
pub fn prepare(e: reference.Kepler, source: records.NavSource) Preparation {
    const sv = described(e, source);
    const failure = failureOf(&sv, e.attribute(source) orelse e.record.extra, source) orelse
        return .{ .choice = .carried, .content = .{ .carried = sv } };
    const why: carriage.Unfit = switch (failure) {
        .field => |name| .{ .field = name },
        .health => |signals| .{ .health = signals },
    };
    return .{ .choice = .{ .unfit = why }, .content = .{ .unfit = why } };
}

pub fn project(e: reference.Kepler, source: records.NavSource, choice: Choice) Content {
    return switch (choice) {
        .carried => .{ .carried = described(e, source) },
        .unfit => |why| .{ .unfit = why },
    };
}

/// CNAV's flags: the record's own, else the declared integrity's, else ISF 0 and alert 0, as LNAV sends them: the legacy
/// integrity level, and a URA that holds.
pub fn cnavFlags(parameters: *const ephemeris.Parameters, declared: ?messages.Integrity, prn: u8) gps_records.CnavFlags {
    if (parameters.flags) |own| return own;
    const d = declared orelse return .{ .integrity_status = false, .l2c_phasing = false, .alert = false };
    return .{ .integrity_status = d.isf == 1, .l2c_phasing = false, .alert = d.alerts(prn) };
}

/// CNAV-2's ISF, as `cnavFlags` gives CNAV's.
pub fn cnav2Isf(parameters: *const ephemeris.Parameters, declared: ?messages.Integrity) bool {
    if (parameters.integrity_status) |own| return own;
    const d = declared orelse return false;
    return d.isf == 1;
}

pub fn misfit(e: *const Eph) ?[:0]const u8 {
    const sv = described(.raw(e), e.source());
    const failure = failureOf(&sv, e.extra, e.source()) orelse return null;
    return switch (failure) {
        .field, .health => |name| name,
    };
}

fn described(e: reference.Kepler, source: records.NavSource) ephemeris.Parameters {
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
    return sv;
}

fn failureOf(sv: *const ephemeris.Parameters, extra: records.SourceExtra, source: records.NavSource) ?Failure {
    if (ephemeris.misfit(sv)) |name| return .{ .field = name };
    if (healthGapOf(extra, source)) |signals| return .{ .health = signals };
    return null;
}

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

fn iscOf(e: reference.Kepler, t_gd: ?f64, signal: Signal, component: Component) f64 {
    const t = t_gd orelse return 0;
    return t - (e.delay(signal, component) orelse t);
}
