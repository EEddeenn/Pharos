const std = @import("std");
const types = @import("shared").core.types;
const time = @import("shared").core.time;
const civil = @import("shared").core.civil;
const fields = @import("../fields.zig");
const records = @import("shared").gnss.glonass.records;
const plausible = @import("shared").gnss.plausible;

pub const Kind = enum { fdma };

pub fn kind(msg: []const u8) ?Kind {
    return if (std.mem.eql(u8, msg, "FDMA")) .fdma else null;
}

pub const Parsed = union(enum) { record: records.GlonassEphemeris, misfit: [:0]const u8, blank: [:0]const u8 };

const unknown_delay_s: f64 = 0.999999999999e9;
const unknown_ft: u4 = 15;

const orbit_fields = [3][3][:0]const u8{ .{ "x", "vx", "ax" }, .{ "y", "vy", "ay" }, .{ "z", "vz", "az" } };

pub fn fromRinex(sat: types.SatId, epoch_utc: civil.Utc, head: [2]f64, body: *const [3][4]?f64, fourth: ?[4]?f64, leap: civil.Leap) Parsed {
    const bn = body[0][3] orelse return .{ .blank = "health" };
    const k = fields.intFromFloat(i32, body[1][3] orelse return .{ .blank = "freq" }) orelse return .{ .misfit = "freq" };
    const freq = types.FreqId.fromInt(k) catch return .{ .misfit = "freq" };
    const en = fields.intFromFloat(u5, body[2][3] orelse return .{ .blank = "en" }) orelse return .{ .misfit = "en" };
    const line: [4]?f64 = fourth orelse @splat(null);
    const status = word(u9, line[0]) catch return .{ .misfit = "status_flags" };
    const flags = word(u3, line[3]) catch return .{ .misfit = "health_flags" };
    const m: ?u2 = if (status) |s| @truncate(s >> 7) else null;
    const modern: ?u9 = if (m == 1) status else null;
    var ft: ?u4 = null;
    if (modern != null) {
        ft = word(u4, line[2]) catch return .{ .misfit = "ft" };
        if (ft == unknown_ft) ft = null;
    }
    const ln = modern != null and (flags orelse 0) & 0b100 != 0;
    var orbit: [3][3]f64 = undefined;
    for (body, &orbit, orbit_fields) |row, *out, names| {
        for (row[0..3], out, names) |v, *o, name| o.* = v orelse return .{ .blank = name };
    }
    const rec: records.GlonassEphemeris = .{
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

fn word(comptime T: type, v: ?f64) error{OutOfRange}!?T {
    return fields.intFromFloat(T, @round(v orelse return null)) orelse error.OutOfRange;
}
