const std = @import("std");
const time = @import("domain/time/gps");
const civil = @import("domain/time/civil");
const json_node = @import("base/json/node");
const json_table = @import("base/json/table");
const GpsTime = time.GpsTime;
const Key = json_table.Key;
const Ctx = json_node.Ctx;
const Error = json_node.Error;

const first_scenario_year = 2000;
const last_scenario_year = 2100;

const TimeType = enum {
    utc,
    gps,
    bds,
    gal,
    glo,

    pub const words: std.EnumArray(TimeType, []const u8) = .init(.{ .utc = "UTC", .gps = "GPS", .bds = "BDS", .gal = "Galileo", .glo = "GLONASS" });
};

const week_form: json_table.Kind = .{ .keys = &.{ .{ .name = "week", .required = true }, .{ .name = "second", .required = true, .range = .{ .min = 0, .max = time.s_per_week, .open_max = true } } } };

pub const Raw = struct {
    type: TimeType = undefined,
    year: ?i32 = null,
    month: ?u8 = null,
    day: ?u16 = null,
    hour: ?u8 = null,
    minute: ?u8 = null,
    second: ?f64 = null,
    week: ?i64 = null,
    leap_year: ?i32 = null,

    pub const table = [_]Key{
        .{ .name = "type", .required = true, .what = "time system", .doc = "the time scale the other keys count in: UTC, GPS, Galileo, BDS or GLONASS" },
        .{ .name = "year", .range = .{ .min = first_scenario_year, .max = last_scenario_year }, .doc = "the UTC year" },
        .{ .name = "month", .range = .{ .min = 1, .max = 12 }, .doc = "the UTC month" },
        .{ .name = "day", .doc = "the UTC day of the month, or the GLONASS day NT of the four-year interval" },
        .{ .name = "hour", .range = .{ .min = 0, .max = 23 }, .doc = "the UTC hour" },
        .{ .name = "minute", .range = .{ .min = 0, .max = 59 }, .doc = "the UTC minute" },
        .{ .name = "second", .unit = "s", .doc = "the second of the UTC minute, of the GPS, Galileo or BDS week, or of the GLONASS day in Moscow time" },
        .{ .name = "week", .range = .{ .min = 0, .max = time.max_week }, .doc = "the week of the scale: the GPS week, the GST week (the GPS week less 1024) or the BDT week (the GPS week less 1356)" },
        .{ .name = "leapYear", .range = .{ .min = 1, .max = 31 }, .doc = "the GLONASS four-year interval N4, counted from 1996" },
    };

    pub const kinds: json_table.Kinds(TimeType) = .{ .key = "type", .of = .init(.{
        .utc = .{ .keys = &.{
            .{ .name = "year", .required = true },
            .{ .name = "month", .required = true },
            .{ .name = "day", .required = true, .range = .{ .min = 1, .max = 31 } },
            .{ .name = "hour", .required = true },
            .{ .name = "minute", .required = true },
            .{ .name = "second", .required = true, .range = .{ .min = 0, .max = 60, .open_max = true } },
        } },
        .gps = week_form,
        .bds = week_form,
        .gal = week_form,
        .glo = .{ .keys = &.{
            .{ .name = "leapYear", .required = true },
            .{ .name = "day", .required = true, .range = .{ .min = 1, .max = civil.glonass_cycle_days } },
            .{ .name = "second", .required = true, .range = .{ .min = 0, .max = time.s_per_day, .open_max = true } },
        } },
    }) };
};

pub fn resolve(raw: Raw, ctx: *const Ctx, path: []const u8) Error!?GpsTime {
    switch (try json_table.kind(Raw, raw, ctx, path) orelse return null) {
        .utc => |given| {
            const utc: civil.Utc = .{
                .year = given.year,
                .month = given.month,
                .day = @intCast(given.day),
                .hour = given.hour,
                .minute = given.minute,
                .second = given.second,
            };
            if (!civil.isDate(utc.year, utc.month, utc.day)) {
                try ctx.diags.err(.out_of_range, try json_node.join(ctx, path, "day"), "{d}-{d:0>2}-{d:0>2} is not a calendar date", .{ utc.year, utc.month, given.day });
                return null;
            }
            return GpsTime.fromUtc(.table, utc);
        },
        inline .gps, .gal, .bds => |given, week_kind| {
            const s = splitMs(given.second);
            return GpsTime.fromScaleWeekMs(@field(time.WeekScale, @tagName(week_kind)), given.week, s.ms, s.sub);
        },
        .glo => |given| {
            const s = splitMs(given.second);
            return GpsTime.fromGlonass(.table, .{ .n4 = given.leap_year, .nt = given.day, .ms_of_day = @intCast(s.ms), .sub_ms = s.sub });
        },
    }
}

fn splitMs(seconds: f64) struct { ms: i64, sub: f64 } {
    const total = seconds * 1000.0;
    const whole = @floor(total);
    return .{ .ms = @intFromFloat(whole), .sub = total - whole };
}
