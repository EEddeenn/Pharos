const std = @import("std");
pub const gps = @import("record/gps.zig");
pub const galileo = @import("record/galileo.zig");
pub const bds = @import("record/bds.zig");
pub const glonass = @import("record/glonass.zig");
const core = @import("shared").core;
const time = core.time;
const records = @import("shared").gnss.records;
const plausible = @import("shared").gnss.plausible;
const fields = @import("fields.zig");

pub const Blank = error{BlankField};
pub const Error = fields.Error || Blank;

pub const Body = struct {
    rows: []const [4]?f64,
    blank: [:0]const u8 = "",

    pub fn get(self: *Body, row: usize, col: usize, comptime name: [:0]const u8) Blank!f64 {
        return self.rows[row][col] orelse {
            self.blank = name;
            return error.BlankField;
        };
    }

    pub fn opt(self: *const Body, row: usize, col: usize) ?f64 {
        return self.rows[row][col];
    }

    pub fn putDelay(self: *const Body, delays: *records.GroupDelays, term: records.GroupDelayTerm, row: usize, col: usize) void {
        if (self.opt(row, col)) |v| delays.put(term, v);
    }
};

pub const Completion = struct {
    toe: time.GpsTime,
    toc: time.GpsTime,
    iode: u16 = 0,
    iodc: u16 = 0,
    top: ?time.GpsTime = null,
    a_dot: f64 = 0,
    delta_n_dot: f64 = 0,
    group_delay: records.GroupDelays = records.GroupDelays.init(.{}),
    extra: @FieldType(records.KeplerEphemeris, "extra"),
};

fn weekField(v: f64) fields.Error!i64 {
    const w = try fields.intField(i64, @round(v));
    if (w < 0 or w > time.max_week) return error.MalformedRecord;
    return w;
}

pub fn sowNearReference(ref: time.ScaleTime, sow: f64) fields.Error!time.GpsTime {
    if (!(sow >= 0 and sow < core.time.s_per_week)) return error.MalformedRecord;
    const s: i64 = @intFromFloat(@round(sow));
    const ref_s: i64 = ref.ms / 1000;
    var week = ref.period;
    if (s - ref_s > plausible.half_week_s) week -= 1;
    if (ref_s - s > plausible.half_week_s) week += 1;
    return time.GpsTime.fromScaleWeekMs(ref.scale, week, s * 1000, 0);
}

pub const Toe = struct { week: i64, ms: i64 };

pub fn toeOfBody(body: *Body) Error!Toe {
    const toe_sow = try body.get(2, 0, "toe");
    if (!(toe_sow >= 0 and toe_sow < core.time.s_per_week)) return error.MalformedRecord;
    return .{ .week = try weekField(try body.get(4, 2, "week")), .ms = @intFromFloat(@round(toe_sow * 1000.0)) };
}

pub fn issueOfBody(body: *Body) Error!u16 {
    return @intCast(try fields.intField(i64, try body.get(0, 0, "iode")) & 0xffff);
}

pub fn clamped(comptime T: type, v: f64) fields.Error!T {
    const n = try fields.intField(i64, @round(v));
    return @intCast(std.math.clamp(n, std.math.minInt(T), std.math.maxInt(T)));
}

pub fn bitsOf(comptime T: type, v: f64) fields.Error!T {
    const n = try fields.intField(i64, @round(v));
    const width = @typeInfo(T).int.bits;
    if (n < -(1 << (width - 1)) or n >= 1 << width) return error.MalformedRecord;
    return @intCast(@mod(n, 1 << width));
}
