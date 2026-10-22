const time = @import("domain/time/gps");

const GpsTime = time.GpsTime;

pub const toa_step_ms = 4_096_000;
pub const galileo_toa_step_ms = 600_000;

pub fn gridTime(scale: time.WeekScale, t: GpsTime) GpsTime {
    const grid: i64 = switch (scale) {
        .gps, .bds => toa_step_ms,
        .gal => galileo_toa_step_ms,
    };
    const st = t.inScale(scale);
    const ms = @divFloor(@as(i64, st.ms) + @divFloor(grid, 2), grid) * grid;
    if (ms >= time.ms_per_week) return GpsTime.fromScaleWeekMs(scale, st.period + 1, 0, 0);
    return GpsTime.fromScaleWeekMs(scale, st.period, ms, 0);
}
