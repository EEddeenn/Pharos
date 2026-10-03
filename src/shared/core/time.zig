const civil = @import("civil.zig");
const types = @import("types.zig");

pub const ms_per_second = civil.ms_per_second;
pub const ms_per_minute = civil.ms_per_minute;
pub const ms_per_day = civil.ms_per_day;
pub const ms_per_week: i64 = 604_800_000;
pub const ms_per_hour = 3_600_000;
pub const s_per_hour = 3600;
pub const s_per_day = 86_400;
pub const s_per_week = 604_800;
pub const week_modulus_8 = 256;
pub const week_modulus_10 = 1024;
pub const week_modulus_12 = 4096;
pub const week_modulus_13 = 8192;
pub const week_modulus_16 = 65536;
pub const bds_week_offset: i64 = 1356;
pub const max_week = 100_000;
pub const gal_week_offset: i64 = 1024;
pub const bds_offset_ms: i64 = 14_000;

pub const WeekScale = enum { gps, bds, gal };

pub fn weekOfIndex(index: i64, per_week: i64, scale: WeekScale) i64 {
    return @divFloor(index, per_week) - switch (scale) {
        .gps => 0,
        .gal => gal_week_offset,
        .bds => bds_week_offset,
    };
}

pub const ScaleTime = struct {
    scale: WeekScale,
    period: i64,
    ms: u32,
    sub_ms: f64,

    pub fn asF64Seconds(self: ScaleTime) f64 {
        return (@as(f64, @floatFromInt(self.ms)) + self.sub_ms) / 1000.0;
    }
};

pub fn Batch(comptime width: usize) type {
    return struct {
        const Self = @This();
        const Vector = @Vector(width, f64);

        values: [width]GpsTime,

        pub fn splat(value: GpsTime) Self {
            return .{ .values = @splat(value) };
        }

        pub fn minusSeconds(self: Self, seconds: Vector) Self {
            var out: Self = undefined;
            inline for (0..width) |i| out.values[i] = self.values[i].minusSeconds(seconds[i]);
            return out;
        }

        pub fn secondsSince(self: Self, base: Self) Vector {
            var out: Vector = undefined;
            inline for (0..width) |i| out[i] = self.values[i].secondsSince(base.values[i]);
            return out;
        }
    };
}

pub const GpsTime = struct {
    ms: i64,
    sub_ms: f64 = 0,

    pub const epoch: GpsTime = .{ .ms = 0 };

    pub fn fromWeekMs(wk: i64, ms_of_week: i64, sub_ms: f64) GpsTime {
        return normalized(wk * ms_per_week + ms_of_week, sub_ms);
    }

    pub fn fromScaleWeekMs(scale: WeekScale, wk: i64, ms_of_week: i64, sub_ms: f64) GpsTime {
        return switch (scale) {
            .gps => fromWeekMs(wk, ms_of_week, sub_ms),
            .gal => fromWeekMs(wk + gal_week_offset, ms_of_week, sub_ms),
            .bds => normalized((wk + bds_week_offset) * ms_per_week + ms_of_week + bds_offset_ms, sub_ms),
        };
    }

    fn normalized(ms: i64, sub_ms: f64) GpsTime {
        const carry = @floor(sub_ms);
        return .{ .ms = ms + @as(i64, @intFromFloat(carry)), .sub_ms = sub_ms - carry };
    }

    fn of(i: civil.Instant) GpsTime {
        return .{ .ms = i.ms, .sub_ms = i.sub_ms };
    }

    pub fn week(self: GpsTime) i64 {
        return @divFloor(self.ms, ms_per_week);
    }

    pub fn msOfWeek(self: GpsTime) u32 {
        return @intCast(@mod(self.ms, ms_per_week));
    }

    pub fn sow(self: GpsTime) f64 {
        return (@as(f64, @floatFromInt(self.msOfWeek())) + self.sub_ms) / 1000.0;
    }

    pub fn addMs(self: GpsTime, n: i64) GpsTime {
        return .{ .ms = self.ms + n, .sub_ms = self.sub_ms };
    }

    pub fn addSeconds(self: GpsTime, s: f64) GpsTime {
        const total_ms = s * 1000.0;
        const whole = @floor(total_ms);
        return normalized(self.ms + @as(i64, @intFromFloat(whole)), self.sub_ms + (total_ms - whole));
    }

    pub fn minusSeconds(self: GpsTime, s: f64) GpsTime {
        return self.addSeconds(-s);
    }

    pub fn secondsSince(self: GpsTime, base: GpsTime) f64 {
        const whole: f64 = @floatFromInt(self.ms - base.ms);
        return (whole + (self.sub_ms - base.sub_ms)) / 1000.0;
    }

    pub fn lessThan(a: GpsTime, b: GpsTime) bool {
        if (a.ms != b.ms) return a.ms < b.ms;
        return a.sub_ms < b.sub_ms;
    }

    pub fn eql(a: GpsTime, b: GpsTime) bool {
        return a.ms == b.ms and a.sub_ms == b.sub_ms;
    }

    pub fn inScale(self: GpsTime, scale: WeekScale) ScaleTime {
        switch (scale) {
            .gps => return .{ .scale = .gps, .period = self.week(), .ms = self.msOfWeek(), .sub_ms = self.sub_ms },
            .gal => return .{ .scale = .gal, .period = self.week() - gal_week_offset, .ms = self.msOfWeek(), .sub_ms = self.sub_ms },
            .bds => {
                const bds_ms = self.ms - bds_offset_ms;
                return .{
                    .scale = .bds,
                    .period = @divFloor(bds_ms, ms_per_week) - bds_week_offset,
                    .ms = @intCast(@mod(bds_ms, ms_per_week)),
                    .sub_ms = self.sub_ms,
                };
            },
        }
    }

    pub fn baseMs(self: GpsTime, system: types.System, schedule: civil.Leap) i64 {
        return switch (system) {
            .gps, .gal => self.ms,
            .bds => self.ms - bds_offset_ms,
            .glo => civil.moscowMs(schedule, self.ms),
        };
    }

    pub fn fromBaseMs(system: types.System, base_ms: i64, schedule: civil.Leap) GpsTime {
        return switch (system) {
            .gps, .gal => .{ .ms = base_ms },
            .bds => .{ .ms = base_ms + bds_offset_ms },
            .glo => of(civil.fromMoscowBase(schedule, base_ms)),
        };
    }

    pub fn leap(self: GpsTime, schedule: civil.Leap) civil.LeapInfo {
        return schedule.atMs(self.ms);
    }

    pub fn toUtc(self: GpsTime, schedule: civil.Leap) civil.Utc {
        return civil.utc(schedule, self.ms, self.sub_ms);
    }

    pub fn toCalendar(self: GpsTime) civil.Utc {
        return civil.calendar(self.ms, self.sub_ms);
    }

    pub fn printed(self: GpsTime, schedule: ?civil.Leap) civil.Printed {
        return civil.printed(self.ms, self.sub_ms, schedule);
    }

    pub fn fromUtc(schedule: civil.Leap, u: civil.Utc) GpsTime {
        return of(civil.fromUtc(schedule, u));
    }

    pub fn fromGpsCalendar(u: civil.Utc) GpsTime {
        const whole = @floor(u.second);
        const ms_of_day = (@as(i64, u.hour) * 3600 + @as(i64, u.minute) * 60 + @as(i64, @intFromFloat(whole))) * 1000;
        return epoch.addMs(civil.calendarMs(u.year, u.month, u.day, ms_of_day)).addSeconds(u.second - whole);
    }

    pub fn toGlonass(self: GpsTime, schedule: civil.Leap) civil.GlonassTime {
        return civil.glonass(schedule, self.ms, self.sub_ms);
    }

    pub fn fromGlonass(schedule: civil.Leap, g: civil.GlonassTime) GpsTime {
        return of(civil.fromGlonass(schedule, g));
    }
};

pub const Epoch = struct {
    ms: u64,

    pub const zero: Epoch = .{ .ms = 0 };

    pub fn plus(self: Epoch, epochs: u64) Epoch {
        return .{ .ms = self.ms + epochs };
    }
};

pub const epochs_per_second: u64 = ms_per_second;

pub fn atEpoch(start: GpsTime, epoch: Epoch) GpsTime {
    return start.addMs(@intCast(epoch.ms));
}

pub fn resolveWeek(raw: i64, modulus: i64, reference_week: i64) i64 {
    if (raw >= modulus) return raw;
    const base = reference_week - @mod(reference_week - raw, modulus);
    return if (reference_week - base > @divFloor(modulus, 2)) base + modulus else base;
}
