const std = @import("std");
const rejections = @import("products/pack/input/rejections");
const diagnostics = @import("base/diagnostics");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const gps = @import("products/pack/input/formats/almanac/gps");
const galileo = @import("products/pack/input/formats/almanac/galileo");
const glonass = @import("products/pack/input/formats/almanac/glonass");
const bds = @import("products/pack/input/formats/almanac/bds");
const GpsTime = @import("domain/time/gps").GpsTime;
const Almanac = @import("domain/navigation/records").Almanac;
const Rejections = rejections.Rejections;

pub const Error = error{ OutOfMemory, MissingIssueDate };

pub const Format = enum { gps_yuma, bds_text, galileo_xml, glonass_agl };

pub fn satOf(system: gnss_types.System, number: i64) ?gnss_types.SatId {
    return gnss_types.SatId.fromPrn(system, std.math.cast(u32, number) orelse return null) catch null;
}

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

pub fn parse(arena: std.mem.Allocator, format: Format, text: []const u8, reference: GpsTime, leap: civil.Leap, scope: diagnostics.Scope) diagnostics.InputError![]Almanac {
    var at: usize = 0;
    var issues: Rejections = .{};
    const result = switch (format) {
        .gps_yuma => gps.read(arena, text, reference, &issues),
        .bds_text => bds.read(arena, text, &issues),
        .galileo_xml => galileo.read(arena, text, leap, &at, &issues),
        .glonass_agl => glonass.read(arena, text, leap, &issues),
    } catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingIssueDate => "the almanac has no usable issue date",
        };
        try issues.report(scope);
        return scope.fail(.invalid_format, if (at == 0) null else .{ .text = .{ .line = @intCast(at) } }, "{s}", .{message});
    };
    try issues.report(scope);
    return result;
}
