const std = @import("std");
const diagnostics = @import("shared").core.diagnostics;
const types = @import("shared").core.types;
const GpsTime = @import("shared").core.time.GpsTime;
const civil = @import("shared").core.civil;
const Almanac = @import("shared").gnss.records.Almanac;
const gps = @import("almanac/gps.zig");
const galileo = @import("almanac/galileo.zig");
const glonass = @import("almanac/glonass.zig");
const bds = @import("almanac/bds.zig");

pub const Error = error{ OutOfMemory, UnknownFormat, MalformedRecord, MissingIssueDate };
pub const Result = struct { almanacs: []Almanac, skipped: u32 };

pub fn satOf(system: types.System, number: i64) ?types.SatId {
    return types.SatId.fromPrn(system, std.math.cast(u32, number) orelse return null) catch null;
}

pub fn keepNewest(list: *std.ArrayList(Almanac), arena: std.mem.Allocator, candidate: Almanac) std.mem.Allocator.Error!void {
    for (list.items) |*existing| {
        if (existing.sat() != candidate.sat()) continue;
        if (issue(candidate) > issue(existing.*)) existing.* = candidate;
        return;
    }
    try list.append(arena, candidate);
}

fn issue(a: Almanac) i64 {
    return switch (a) {
        .kepler => |k| k.toa.ms,
        .glonass => |g| @as(i64, g.n4) * civil.glonass_cycle_days + g.na,
    };
}

pub const Format = enum { gps_yuma, bds_text, galileo_xml, glonass_agl };

pub fn detect(text: []const u8) ?Format {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        if (gps.matches(line)) return .gps_yuma;
        if (galileo.matches(line)) return .galileo_xml;
        if (glonass.matches(line)) return .glonass_agl;
        if (bds.matches(line)) return .bds_text;
        return null;
    }
    return null;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8, reference: GpsTime, leap: civil.Leap, scope: diagnostics.Scope) diagnostics.InputError!Result {
    var at: usize = 0;
    return parseRaw(arena, text, reference, leap, &at) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownFormat => "the almanac format is not recognized",
            error.MalformedRecord => "an almanac record is malformed",
            error.MissingIssueDate => "the almanac has no usable issue date",
        };
        return scope.fail(.invalid_format, if (at == 0) null else .{ .line = @intCast(at) }, "{s}", .{message});
    };
}

fn parseRaw(arena: std.mem.Allocator, text: []const u8, reference: GpsTime, leap: civil.Leap, at: *usize) Error!Result {
    return switch (detect(text) orelse return error.UnknownFormat) {
        .gps_yuma => gps.read(arena, text, reference),
        .bds_text => bds.read(arena, text, at),
        .galileo_xml => galileo.read(arena, text, leap, at),
        .glonass_agl => glonass.read(arena, text, leap, at),
    };
}
