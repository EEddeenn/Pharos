const field = @import("../codec.zig").field;
const time = @import("../core.zig").time;
const GpsTime = time.GpsTime;
const galileo_almanac = @import("galileo/almanac_fields.zig");

pub const toa_step_ms = 4_096_000;

pub const Reference = struct {
    wna: u13,
    toa: u8,

    pub fn fromTime(t: time.GpsTime, scale: time.WeekScale) Reference {
        const in = t.inScale(scale);
        return .{ .wna = @intCast(@mod(in.period, time.week_modulus_13)), .toa = @intCast(in.ms / toa_step_ms) };
    }
};

pub const rows = [_]field.Field(Reference){
    .{ .name = "wna", .width = 13, .src = .{ .field = "wna" } },
    .{ .name = "toa", .width = 8, .src = .{ .field = "toa" } },
};

pub fn gridTime(scale: time.WeekScale, t: GpsTime) GpsTime {
    const grid: i64 = switch (scale) {
        .gps, .bds => toa_step_ms,
        .gal => galileo_almanac.t0a_step_ms,
    };
    const st = t.inScale(scale);
    const ms = @divFloor(@as(i64, st.ms) + @divFloor(grid, 2), grid) * grid;
    if (ms >= time.ms_per_week) return GpsTime.fromScaleWeekMs(scale, st.period + 1, 0, 0);
    return GpsTime.fromScaleWeekMs(scale, st.period, ms, 0);
}
