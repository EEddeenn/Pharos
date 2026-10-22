const std = @import("std");
const time = @import("domain/time/gps");
const fields = @import("products/pack/input/navigation/fields");
const records = @import("domain/navigation/records");
const almanac = @import("products/pack/input/formats/almanac/read");
const rejections = @import("products/pack/input/rejections");
const Rejections = rejections.Rejections;

const GpsTime = time.GpsTime;
const Almanac = records.Almanac;

const Block = struct {
    label: []const u8 = "",
    line: usize = 0,
    invalid: ?[:0]const u8 = null,
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
            if (self.id == null) self.invalid = "id";
        } else if (std.ascii.startsWithIgnoreCase(label, "Health")) {
            self.health = fields.int(u8, value);
            if (self.health == null) self.invalid = "health";
        } else if (std.ascii.startsWithIgnoreCase(label, "Eccentricity")) {
            self.ecc = fields.float(value);
            if (self.ecc == null) self.invalid = "ecc";
        } else if (std.ascii.startsWithIgnoreCase(label, "Time of Applicability")) {
            self.toa = fields.float(value);
            if (self.toa == null) self.invalid = "toa";
        } else if (std.ascii.startsWithIgnoreCase(label, "Orbital Inclination")) {
            self.i0 = fields.float(value);
            if (self.i0 == null) self.invalid = "i0";
        } else if (std.ascii.startsWithIgnoreCase(label, "Rate of Right Ascen")) {
            self.omega_dot = fields.float(value);
            if (self.omega_dot == null) self.invalid = "omega_dot";
        } else if (std.ascii.startsWithIgnoreCase(label, "SQRT(A)")) {
            self.sqrt_a = fields.float(value);
            if (self.sqrt_a == null) self.invalid = "sqrt_a";
        } else if (std.ascii.startsWithIgnoreCase(label, "Right Ascen at Week")) {
            self.omega0 = fields.float(value);
            if (self.omega0 == null) self.invalid = "omega0";
        } else if (std.ascii.startsWithIgnoreCase(label, "Argument of Perigee")) {
            self.w = fields.float(value);
            if (self.w == null) self.invalid = "w";
        } else if (std.ascii.startsWithIgnoreCase(label, "Mean Anom")) {
            self.m0 = fields.float(value);
            if (self.m0 == null) self.invalid = "m0";
        } else if (std.ascii.startsWithIgnoreCase(label, "Af0")) {
            self.af0 = fields.float(value);
            if (self.af0 == null) self.invalid = "af0";
        } else if (std.ascii.startsWithIgnoreCase(label, "Af1")) {
            self.af1 = fields.float(value);
            if (self.af1 == null) self.invalid = "af1";
        } else if (std.ascii.startsWithIgnoreCase(label, "week")) {
            self.week = fields.int(i64, value);
            if (self.week == null) self.invalid = "week";
        }
    }

    fn finish(self: Block, reference: GpsTime, rejected: *rejections.Rejection) rejections.RecordError!?Almanac {
        if (self.invalid) |name| return rejected.fail(name, null, .malformed);
        const id = self.id orelse return rejected.fail("id", null, .blank);
        const health = self.health orelse return rejected.fail("health", null, .blank);
        const ecc = self.ecc orelse return rejected.fail("ecc", null, .blank);
        const toa = self.toa orelse return rejected.fail("toa", null, .blank);
        const inclination = self.i0 orelse return rejected.fail("i0", null, .blank);
        const omega_dot = self.omega_dot orelse return rejected.fail("omega_dot", null, .blank);
        const sqrt_a = self.sqrt_a orelse return rejected.fail("sqrt_a", null, .blank);
        const omega0 = self.omega0 orelse return rejected.fail("omega0", null, .blank);
        const w = self.w orelse return rejected.fail("w", null, .blank);
        const m0 = self.m0 orelse return rejected.fail("m0", null, .blank);
        const af0 = self.af0 orelse return rejected.fail("af0", null, .blank);
        const af1 = self.af1 orelse return rejected.fail("af1", null, .blank);
        const week = self.week orelse return rejected.fail("week", null, .blank);
        const sat = almanac.satOf(.gps, id) orelse {
            if (id > 0) return null;
            return rejected.fail("epoch or satellite", null, .implausible);
        };
        if (toa < 0 or toa >= time.s_per_week or week < 0 or week > time.max_week) return rejected.fail("epoch or satellite", null, .implausible);
        return .{ .kepler = .{
            .sat = sat,
            .toa = GpsTime.fromWeekMs(time.resolveWeek(week, time.week_modulus_10, reference.week()), @intFromFloat(@round(toa * 1000.0)), 0),
            .health = health,
            .iod = 0,
            .ecc = ecc,
            .sqrt_a = sqrt_a,
            .omega0 = omega0,
            .i0 = inclination,
            .w = w,
            .omega_dot = omega_dot,
            .m0 = m0,
            .af0 = af0,
            .af1 = af1,
        } };
    }
};

pub fn matches(line: []const u8) bool {
    return line.len > 0 and line[0] == '*';
}

pub fn read(arena: std.mem.Allocator, source: []const u8, reference: GpsTime, issues: *Rejections) std.mem.Allocator.Error![]Almanac {
    var list: std.ArrayList(Almanac) = .empty;
    var block: ?Block = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '*') {
            if (block) |value| try finish(&list, arena, issues, value, reference);
            block = .{ .label = line, .line = number };
        } else if (block) |*value| value.take(line);
    }
    if (block) |value| try finish(&list, arena, issues, value, reference);
    return list.items;
}

fn finish(list: *std.ArrayList(Almanac), arena: std.mem.Allocator, issues: *Rejections, block: Block, reference: GpsTime) std.mem.Allocator.Error!void {
    var rejected: rejections.Rejection = .{ .system = .gps, .message = "YUMA almanac", .named = .{ .label = block.label }, .location = .{ .text = .{ .line = std.math.lossyCast(u32, block.line) } } };
    const value = block.finish(reference, &rejected) catch {
        try issues.add(arena, rejected);
        return;
    };
    if (value) |accepted| try list.append(arena, accepted) else issues.ignore();
}
