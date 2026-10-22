const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const civil = @import("domain/time/civil");
const angles = @import("base/math/angles");
const geoid = @import("domain/earth/geoid/model");

const GpsTime = @import("domain/time/gps").GpsTime;

const Ecef = coordinates.Ecef;
const Lla = coordinates.Lla;
const Writer = std.Io.Writer;

pub const Kind = enum(u32) {
    ecef = 0,
    lla = 1,

    pub const words: std.EnumArray(Kind, []const u8) = .init(.{ .ecef = "ECEF", .lla = "LLA" });
};

pub fn header(kind: Kind) []const u8 {
    return switch (kind) {
        .ecef => "%  GPST                      x-ecef(m)      y-ecef(m)      z-ecef(m)\n",
        .lla => "%  GPST                  latitude(deg) longitude(deg)  height(m)\n",
    };
}

pub fn ecefLine(w: *Writer, t: GpsTime, pos: Ecef) Writer.Error!void {
    try stamp(w, t);
    try w.print(" {d:>14.4} {d:>14.4} {d:>14.4}\n", .{ pos.x, pos.y, pos.z });
}

pub fn llaLine(w: *Writer, t: GpsTime, p: Lla) Writer.Error!void {
    try stamp(w, t);
    try w.print(" {d:>14.9} {d:>14.9} {d:>10.4}\n", .{ angles.rad2deg(p.lat_rad), angles.rad2deg(p.lon_rad), geoid.altitude(p) });
}

fn stamp(w: *Writer, t: GpsTime) Writer.Error!void {
    const c = civil.calendar(t.ms + @as(i64, @intFromFloat(@round(t.sub_ms))), 0);
    try w.print("{d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>6.3}", .{ @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second });
}
