const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const fields = @import("products/pack/input/navigation/fields");
const glonass_records = @import("domain/navigation/records/glonass");
const plausible = @import("products/pack/input/admission/navigation");

pub const Kind = enum { fdma };

pub const Parsed = union(enum) { record: glonass_records.GlonassEphemeris, misfit: [:0]const u8, blank: [:0]const u8, non_integral: [:0]const u8 };

const unknown_delay_s: f64 = 0.999999999999e9;
const unknown_ft: u4 = 15;

const orbit_fields = [3][3][:0]const u8{ .{ "x", "vx", "ax" }, .{ "y", "vy", "ay" }, .{ "z", "vz", "az" } };

pub fn kind(msg: []const u8) ?Kind {
    return if (std.mem.eql(u8, msg, "FDMA")) .fdma else null;
}

pub fn fromRinex(sat: gnss_types.SatId, epoch_utc: civil.Utc, head: [2]f64, body: *const [3][4]?f64, fourth: ?[4]?f64, leap: civil.Leap) Parsed {
    const bn = fields.integerValue(u3, body[0][3] orelse return .{ .blank = "health" }) catch |err| return integerFailure("health", err);
    const k = fields.integerValue(i32, body[1][3] orelse return .{ .blank = "freq" }) catch |err| return integerFailure("freq", err);
    const freq = gnss_types.FreqId.fromInt(k) catch return .{ .misfit = "freq" };
    const en = fields.integerValue(u5, body[2][3] orelse return .{ .blank = "en" }) catch |err| return integerFailure("en", err);
    const line: [4]?f64 = fourth orelse @splat(null);
    const status = word(u9, line[0]) catch |err| return integerFailure("status_flags", err);
    const flags = word(u3, line[3]) catch |err| return integerFailure("health_flags", err);
    const m: ?u2 = if (status) |s| @truncate(s >> 7) else null;
    const modern: ?u9 = if (m == 1) status else null;
    var ft: ?u4 = null;
    if (modern != null) {
        ft = word(u4, line[2]) catch |err| return integerFailure("ft", err);
        if (ft == unknown_ft) ft = null;
    }
    const ln = modern != null and (flags orelse 0) & 0b100 != 0;
    var orbit: [3][3]f64 = undefined;
    for (body, &orbit, orbit_fields) |row, *out, names| {
        for (row[0..3], out, names) |v, *o, name| o.* = v orelse return .{ .blank = name };
    }
    const rec: glonass_records.GlonassEphemeris = .{
        .sat = sat,
        .freq = freq,
        .tb = time.GpsTime.fromUtc(leap, epoch_utc),
        .pos = .{ orbit[0][0] * 1e3, orbit[1][0] * 1e3, orbit[2][0] * 1e3 },
        .vel = .{ orbit[0][1] * 1e3, orbit[1][1] * 1e3, orbit[2][1] * 1e3 },
        .acc = .{ orbit[0][2] * 1e3, orbit[1][2] * 1e3, orbit[2][2] * 1e3 },
        .gamma_n = head[1],
        .tau_n = -head[0],
        .delta_tau_n = if (line[1]) |d| (if (d == unknown_delay_s) null else d) else null,
        .health = bn == 0 and !ln,
        .almanac_health = if (flags) |f| (if (f & 0b010 != 0) f & 0b001 != 0 else null) else null,
        .ft = ft,
        .en = en,
        .p = if (modern) |s| @truncate(s & 0b11) else null,
        .p1 = 0,
        .p4 = if (modern) |s| s & 0b1000000 != 0 else null,
        .m = m,
    };
    if (plausible.glonass(&rec, leap)) |name| return .{ .misfit = name };
    return .{ .record = rec };
}

fn word(comptime T: type, value: ?f64) fields.IntegerError!?T {
    return try fields.integerValue(T, value orelse return null);
}

fn integerFailure(name: [:0]const u8, err: fields.IntegerError) Parsed {
    return switch (err) {
        error.NonIntegral => .{ .non_integral = name },
        error.OutOfRange => .{ .misfit = name },
    };
}
