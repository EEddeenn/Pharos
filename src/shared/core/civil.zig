const std = @import("std");
pub const ms_per_second: i64 = 1000;
pub const ms_per_minute: i64 = 60_000;
pub const ms_per_day: i64 = 86_400_000;
const gps_epoch_unix_days: i64 = 3657;
const moscow_offset_ms: i64 = 10_800_000;
const glonass_cycle_origin_year: i32 = 1996;
pub const glonass_cycle_days = 1461;
pub const first_year = 1980;
pub const last_year = 9999;

const leap_table = [18]i64{
    46828800,  78364801,  109900802, 173059203,  252028804,  315187205,
    346723206, 393984007, 425520008, 457056009,  504489610,  551750411,
    599184012, 820108813, 914803214, 1025136015, 1119744016, 1167264017,
};

pub const LeapInfo = struct {
    count: i8,
    at_leap: bool,
};

pub const Leap = struct {
    table_insertions: u8 = leap_table.len,
    count: i8 = leap_table.len,
    event: ?Change = null,

    pub const Change = struct { at_ms: i64, count: i8 };

    pub const table: Leap = .{};

    const Period = struct { info: LeapInfo, until_second: ?i64 };

    fn periodAtSecond(self: Leap, gps_seconds: i64) Period {
        for (leap_table[0..self.table_insertions], 0..) |t, i| {
            if (gps_seconds <= t) return .{
                .info = .{ .count = @intCast(i), .at_leap = gps_seconds == t },
                .until_second = if (gps_seconds < t) t else t + 1,
            };
        }
        const event = self.event orelse return .{ .info = .{ .count = self.count, .at_leap = false }, .until_second = null };
        const from = @divFloor(event.at_ms, ms_per_second);
        if (gps_seconds >= from) return .{ .info = .{ .count = event.count, .at_leap = false }, .until_second = null };
        const inserted: i64 = event.count - self.count;
        const at_leap = inserted > 0 and gps_seconds >= from - inserted;
        return .{
            .info = .{ .count = self.count, .at_leap = at_leap },
            .until_second = if (at_leap) from else from - @max(inserted, 0),
        };
    }

    fn atSecond(self: Leap, gps_seconds: i64) LeapInfo {
        return self.periodAtSecond(gps_seconds).info;
    }

    pub fn atMs(self: Leap, ms: i64) LeapInfo {
        return self.atSecond(@divFloor(ms, ms_per_second));
    }

    pub fn nextChange(self: Leap, ms: i64) ?Change {
        for (leap_table[0..self.table_insertions], 0..) |t, i| {
            const at_ms = (t + 1) * ms_per_second;
            if (at_ms >= ms) return .{ .at_ms = at_ms, .count = @intCast(i + 1) };
        }
        const event = self.event orelse return null;
        return if (event.at_ms >= ms and event.count != self.count) event else null;
    }

    pub fn lastInsertion(self: Leap) ?Change {
        if (self.table_insertions == 0 or self.count != self.table_insertions) return null;
        return .{ .at_ms = (leap_table[self.table_insertions - 1] + 1) * ms_per_second, .count = self.count };
    }

    pub fn insertionsAt(ms: i64) u8 {
        const info = table.atMs(ms);
        return @intCast(@as(i16, info.count) + @intFromBool(info.at_leap));
    }

    pub fn valid(self: Leap) bool {
        if (self.table_insertions > leap_table.len or self.count < 0) return false;
        if (self.table_insertions < leap_table.len and self.count != self.table_insertions) return false;
        const event = self.event orelse return true;
        const step = @as(i16, event.count) - self.count;
        return event.at_ms > 0 and step >= -1 and step <= 1 and
            @mod(event.at_ms, ms_per_day) == @mod(@as(i64, event.count) * ms_per_second, ms_per_day);
    }
};

pub const Instant = struct { ms: i64, sub_ms: f64 };

pub const Utc = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: f64,

    pub fn format(self: Utc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(self.year)), self.month, self.day, self.hour, self.minute, @as(u8, @intFromFloat(@floor(self.second))) });
    }
};

const us_per_ms = 1000;
const us_per_second = us_per_ms * ms_per_second;
const fraction_digits = 6;

pub const Printed = struct {
    us: i64,
    leap: ?Leap,

    pub fn format(self: Printed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const ms = @divFloor(self.us, us_per_ms);
        try w.print("{f}", .{if (self.leap) |leap| utc(leap, ms, 0) else calendar(ms, 0)});
        var fraction: u32 = @intCast(@mod(self.us, us_per_second));
        if (fraction != 0) {
            var digits: usize = fraction_digits;
            while (fraction % 10 == 0) : (digits -= 1) fraction /= 10;
            try w.print(".{d:0>[1]}", .{ fraction, digits });
        }
        try w.writeAll(if (self.leap == null) " GPST" else " UTC");
    }
};

pub fn printed(ms: i64, sub_ms: f64, leap: ?Leap) Printed {
    return .{ .us = ms * us_per_ms + @as(i64, @intFromFloat(@round(sub_ms * us_per_ms))), .leap = leap };
}

pub const GlonassTime = struct {
    n4: i32,
    nt: u16,
    ms_of_day: u32,
    sub_ms: f64,
};

pub const Civil = struct { year: i32, month: u8, day: u8 };

pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) year - 1 else year;
    const m: i64 = month;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

pub fn civilFromDays(days: i64) Civil {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = @intCast(if (m <= 2) y + 1 else y), .month = @intCast(m), .day = @intCast(d) };
}

pub fn fromUnix(seconds: i64) Utc {
    const date = civilFromDays(@divFloor(seconds, 86_400));
    const sod: u32 = @intCast(@mod(seconds, 86_400));
    return .{ .year = date.year, .month = date.month, .day = date.day, .hour = @intCast(sod / 3600), .minute = @intCast(sod % 3600 / 60), .second = @floatFromInt(sod % 60) };
}

pub fn utc(leap: Leap, ms: i64, sub_ms: f64) Utc {
    const info = leap.atMs(ms);
    const shift: i64 = @as(i64, info.count) + @intFromBool(info.at_leap);
    return calendarOf(ms - shift * ms_per_second, sub_ms, info.at_leap);
}

pub fn calendar(ms: i64, sub_ms: f64) Utc {
    return calendarOf(ms, sub_ms, false);
}

pub fn calendarMs(year: i32, month: u8, day: u8, ms_of_day: i64) i64 {
    return (daysFromCivil(year, month, day) - gps_epoch_unix_days) * ms_per_day + ms_of_day;
}

fn calendarOf(ms: i64, sub_ms: f64, at_leap: bool) Utc {
    const days = @divFloor(ms, ms_per_day);
    const ms_of_day = @mod(ms, ms_per_day);
    const date = civilFromDays(days + gps_epoch_unix_days);
    const seconds_of_day = @divFloor(ms_of_day, ms_per_second);
    const hour = @divFloor(seconds_of_day, 3600);
    const minute = @divFloor(seconds_of_day - hour * 3600, 60);
    const ms_in_minute = @mod(ms_of_day, ms_per_minute);
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = (@as(f64, @floatFromInt(ms_in_minute)) + sub_ms) / 1000.0 + @as(f64, @floatFromInt(@intFromBool(at_leap))),
    };
}

pub fn fromUtc(leap: Leap, u: Utc) Instant {
    const total_ms_f = u.second * 1000.0;
    const ms_in_second: i64 = @intFromFloat(@trunc(total_ms_f));
    const sub_ms = total_ms_f - @as(f64, @floatFromInt(ms_in_second));
    const days = daysFromCivil(u.year, u.month, u.day) - gps_epoch_unix_days;
    const ms_of_day = (@as(i64, u.hour) * 3600 + @as(i64, u.minute) * 60) * ms_per_second + ms_in_second;
    return fromUtcDayMs(leap, days, ms_of_day, sub_ms);
}

fn fromUtcDayMs(leap: Leap, days: i64, ms_of_day: i64, sub_ms: f64) Instant {
    const seconds_of_day = @divFloor(ms_of_day, ms_per_second);
    const naive = days * 86_400 + seconds_of_day;
    const at_midnight = seconds_of_day == 0;
    var first_pass = naive;
    var info = leap.atSecond(first_pass);
    first_pass += info.count;
    info = leap.atSecond(first_pass);
    const total = naive + info.count + @intFromBool(info.at_leap and at_midnight);
    return .{ .ms = total * ms_per_second + @mod(ms_of_day, ms_per_second), .sub_ms = sub_ms };
}

pub fn fromGlonass(leap: Leap, g: GlonassTime) Instant {
    const year0: i32 = glonass_cycle_origin_year + 4 * (g.n4 - 1);
    const moscow_days = daysFromCivil(year0, 1, 1) + g.nt - 1;
    const utc_ms = moscow_days * ms_per_day + g.ms_of_day - moscow_offset_ms;
    const days = @divFloor(utc_ms, ms_per_day) - gps_epoch_unix_days;
    return fromUtcDayMs(leap, days, @mod(utc_ms, ms_per_day), g.sub_ms);
}

pub fn fromMoscowBase(leap: Leap, base_ms: i64) Instant {
    const utc_ms = base_ms - moscow_offset_ms;
    return fromUtcDayMs(leap, @divFloor(utc_ms, ms_per_day), @mod(utc_ms, ms_per_day), 0);
}

pub fn quarterEndStep(leap: Leap, ms: i64) i8 {
    const u = utc(leap, ms, 0);
    const next: u8 = (u.month - 1) / 3 * 3 + 4;
    const end = fromUtc(leap, if (next > 12)
        .{ .year = u.year + 1, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }
    else
        .{ .year = u.year, .month = next, .day = 1, .hour = 0, .minute = 0, .second = 0 });
    const change = leap.nextChange(ms) orelse return 0;
    return if (change.at_ms == end.ms) change.count - leap.atMs(ms).count else 0;
}

pub fn moscowMs(leap: Leap, ms: i64) i64 {
    const info = leap.atMs(ms);
    const shift: i64 = @as(i64, info.count) + @intFromBool(info.at_leap);
    return ms - shift * ms_per_second + moscow_offset_ms;
}

pub fn nextMoscowGrid(leap: Leap, ms: i64, period_ms: i64) i64 {
    var first = ms + 1;
    while (true) {
        const period = leap.periodAtSecond(@divFloor(first, ms_per_second));
        const shift = (@as(i64, period.info.count) + @intFromBool(period.info.at_leap)) * ms_per_second;
        const next = first + @mod(shift - moscow_offset_ms - first, period_ms);
        const until = (period.until_second orelse return next) * ms_per_second;
        if (next < until) return next;
        first = until;
    }
}

pub fn glonass(leap: Leap, ms: i64, sub_ms: f64) GlonassTime {
    const moscow_ms = moscowMs(leap, ms);
    const days = @divFloor(moscow_ms, ms_per_day);
    const date = civilFromDays(days + gps_epoch_unix_days);
    const years = date.year - glonass_cycle_origin_year;
    const in_cycle: i32 = @mod(years, 4);
    const doy: i32 = @intCast(days - (daysFromCivil(date.year, 1, 1) - gps_epoch_unix_days) + 1);
    const nt: i32 = if (in_cycle == 0) doy else doy + 366 + 365 * (in_cycle - 1);
    return .{
        .n4 = @divFloor(years, 4) + 1,
        .nt = @intCast(nt),
        .ms_of_day = @intCast(@mod(moscow_ms, ms_per_day)),
        .sub_ms = sub_ms,
    };
}
