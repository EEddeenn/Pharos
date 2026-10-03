const std = @import("std");
const time = @import("shared").core.time;
const fields = @import("../fields.zig");
const records = @import("shared").gnss.records;
const almanac = @import("../almanac.zig");

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

const Block = struct {
    id: ?i64 = null,
    health: ?u8 = null,
    ecc: ?f64 = null,
    toa: ?f64 = null,
    i0: ?f64 = null,
    omega_dot: ?f64 = null,
    sqrt_a: ?f64 = null,
    omega0: ?f64 = null,
    w: ?f64 = null,
    m0: ?f64 = null,
    af0: ?f64 = null,
    af1: ?f64 = null,
    week: ?i64 = null,

    fn take(self: *Block, line: []const u8) void {
        const colon = std.mem.findScalar(u8, line, ':') orelse return;
        const label = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.ascii.startsWithIgnoreCase(label, "ID")) {
            self.id = fields.int(i64, value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Health")) {
            self.health = fields.int(u8, value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Eccentricity")) {
            self.ecc = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Time of Applicability")) {
            self.toa = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Orbital Inclination")) {
            self.i0 = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Rate of Right Ascen")) {
            self.omega_dot = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "SQRT(A)")) {
            self.sqrt_a = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Right Ascen at Week")) {
            self.omega0 = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Argument of Perigee")) {
            self.w = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Mean Anom")) {
            self.m0 = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Af0")) {
            self.af0 = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "Af1")) {
            self.af1 = fields.float(value);
        } else if (std.ascii.startsWithIgnoreCase(label, "week")) {
            self.week = fields.int(i64, value);
        }
    }

    fn finish(self: Block, reference: GpsTime) ?Almanac {
        const id = self.id orelse return null;
        const health = self.health orelse return null;
        const toa = self.toa orelse return null;
        const week = self.week orelse return null;
        if (toa < 0 or toa >= time.s_per_week or week < 0 or week > time.max_week) return null;
        const sat = almanac.satOf(.gps, id) orelse return null;
        return .{ .kepler = .{
            .sat = sat,
            .toa = GpsTime.fromWeekMs(time.resolveWeek(week, time.week_modulus_10, reference.week()), @intFromFloat(@round(toa * 1000.0)), 0),
            .health = health,
            .iod = 0,
            .ecc = self.ecc orelse return null,
            .sqrt_a = self.sqrt_a orelse return null,
            .omega0 = self.omega0 orelse return null,
            .i0 = self.i0 orelse return null,
            .w = self.w orelse return null,
            .omega_dot = self.omega_dot orelse return null,
            .m0 = self.m0 orelse return null,
            .af0 = self.af0 orelse return null,
            .af1 = self.af1 orelse return null,
        } };
    }
};

pub fn matches(line: []const u8) bool {
    return line.len > 0 and line[0] == '*';
}

pub fn read(arena: std.mem.Allocator, source: []const u8, reference: GpsTime) std.mem.Allocator.Error!almanac.Result {
    var list: std.ArrayList(Almanac) = .empty;
    var skipped: u32 = 0;
    var block: ?Block = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '*') {
            if (block) |b| try finish(&list, arena, &skipped, b, reference);
            block = .{};
        } else if (block) |*b| b.take(line);
    }
    if (block) |b| try finish(&list, arena, &skipped, b, reference);
    return .{ .almanacs = list.items, .skipped = skipped };
}

fn finish(list: *std.ArrayList(Almanac), arena: std.mem.Allocator, skipped: *u32, block: Block, reference: GpsTime) std.mem.Allocator.Error!void {
    if (block.finish(reference)) |a| try list.append(arena, a) else skipped.* += 1;
}
