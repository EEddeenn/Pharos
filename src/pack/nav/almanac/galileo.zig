const std = @import("std");
const time = @import("shared").core.time;
const civil = @import("shared").core.civil;
const fields = @import("../fields.zig");
const records = @import("shared").gnss.records;
const almanac = @import("../almanac.zig");
const constants = @import("shared").gnss.galileo.constants;

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

fn tagValue(block: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const start = (std.mem.find(u8, block, open) orelse return null) + open.len;
    const end = std.mem.findPos(u8, block, start, "</" ++ tag ++ ">") orelse return null;
    return std.mem.trim(u8, block[start..end], " \t\r\n");
}

pub fn matches(line: []const u8) bool {
    return line.len > 0 and line[0] == '<';
}

pub fn read(arena: std.mem.Allocator, source: []const u8, leap: civil.Leap, at: *usize) almanac.Error!almanac.Result {
    const issue_time = issueDate(source, leap) orelse {
        at.* = fields.lineOf(source, if (std.mem.find(u8, source, "<issueDate>")) |i| i + 1 else null);
        return error.MissingIssueDate;
    };
    const gal_week = issue_time.week() - time.gal_week_offset;

    var list: std.ArrayList(Almanac) = .empty;
    var skipped: u32 = 0;
    var cursor: usize = 0;
    while (std.mem.findPos(u8, source, cursor, "<svAlmanac>")) |start| {
        const end = std.mem.findPos(u8, source, start, "</svAlmanac>") orelse break;
        cursor = end + "</svAlmanac>".len;
        if (svBlock(source[start..end], gal_week)) |a| try list.append(arena, a) else skipped += 1;
    }
    return .{ .almanacs = list.items, .skipped = skipped };
}

fn issueDate(source: []const u8, leap: civil.Leap) ?GpsTime {
    const issue = tagValue(source, "issueDate") orelse return null;
    var parts = std.mem.splitScalar(u8, issue, '-');
    const year = fields.int(i32, parts.next() orelse "") orelse return null;
    const month = fields.int(u8, parts.next() orelse "") orelse return null;
    const day = fields.int(u8, std.mem.sliceTo(parts.next() orelse "", 'T')) orelse return null;
    if (year < civil.first_year or year > civil.last_year or month < 1 or month > 12 or day < 1 or day > 31) return null;
    return GpsTime.fromUtc(leap, .{ .year = year, .month = month, .day = day, .hour = 0, .minute = 0, .second = 0 });
}

fn svBlock(source: []const u8, gal_week: i64) ?Almanac {
    const svid = fields.int(i64, tagValue(source, "SVID") orelse return null) orelse return null;
    const sat = almanac.satOf(.gal, svid) orelse return null;
    const iod = fields.int(u8, tagValue(source, "iod") orelse return null) orelse return null;
    const t0a = fields.int(i64, tagValue(source, "t0a") orelse return null) orelse return null;
    const wna = fields.int(u2, tagValue(source, "wna") orelse return null) orelse return null;
    if (t0a < 0 or t0a >= time.s_per_week) return null;
    const week = time.resolveWeek(wna, 4, gal_week);
    const e5a = fields.int(u2, tagValue(source, "statusE5a") orelse "0") orelse return null;
    const e5b = fields.int(u2, tagValue(source, "statusE5b") orelse "0") orelse return null;
    const e1b = fields.int(u2, tagValue(source, "statusE1B") orelse "0") orelse return null;
    return .{ .kepler = .{
        .sat = sat,
        .toa = GpsTime.fromScaleWeekMs(.gal, week, t0a * 1000, 0),
        .health = (@as(u8, e5a) << 4) | (@as(u8, e5b) << 2) | e1b,
        .iod = iod,
        .ecc = fields.float(tagValue(source, "ecc") orelse return null) orelse return null,
        .sqrt_a = (fields.float(tagValue(source, "aSqRoot") orelse return null) orelse return null) + constants.sqrt_a_ref,
        .omega0 = (fields.float(tagValue(source, "omega0") orelse return null) orelse return null) * std.math.pi,
        .i0 = (fields.float(tagValue(source, "deltai") orelse return null) orelse return null) * std.math.pi + constants.nominal_i0,
        .w = (fields.float(tagValue(source, "w") orelse return null) orelse return null) * std.math.pi,
        .omega_dot = (fields.float(tagValue(source, "omegaDot") orelse return null) orelse return null) * std.math.pi,
        .m0 = (fields.float(tagValue(source, "m0") orelse return null) orelse return null) * std.math.pi,
        .af0 = fields.float(tagValue(source, "af0") orelse return null) orelse return null,
        .af1 = fields.float(tagValue(source, "af1") orelse return null) orelse return null,
    } };
}
