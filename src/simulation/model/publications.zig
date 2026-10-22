const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const publication = @import("domain/messages/publication");
const gps = @import("domain/messages/gps/publication");
const cnav2 = @import("domain/messages/gps/cnav2/publications");
const inav = @import("domain/messages/galileo/inav/ism");
const d2 = @import("domain/messages/bds/d1d2/augmentation");
const allocation = @import("domain/signals/allocation/gps");
const GpsTime = @import("domain/time/gps").GpsTime;

pub const lookahead_ms: i64 = 2000;

pub const Publications = struct {
    gps: []const gps.Publication = &.{},
    inav: []const inav.Publication = &.{},
    d2: []const d2.Publication = &.{},

    pub fn declaresDifferential(self: *const Publications) bool {
        for (self.gps) |p| if (p.content.differential != null) return true;
        return false;
    }
};

pub const Prepared = struct {
    gps: []const cnav2.PreparedPublication = &.{},
    inav: []const inav.PreparedPublication = &.{},
    d2: []const d2.PreparedPublication = &.{},
    configuration: [63]u3 = @splat(0),
    cnav2_configuration: ?cnav2.Payload = null,

    pub fn init(allocator: std.mem.Allocator, declarations: Publications, families: std.EnumSet(gnss_types.NavFamily), start: GpsTime) std.mem.Allocator.Error!Prepared {
        const gps_needed = families.contains(.lnav) or families.contains(.cnav) or families.contains(.cnav2);
        const configuration = allocation.configurationAt(start);
        const gps_publications = if (gps_needed) blk: {
            const out = try allocator.alloc(cnav2.PreparedPublication, declarations.gps.len);
            for (declarations.gps, out) |*source, *result| result.* = .{
                .from = source.from,
                .until = source.until,
                .content = if (families.contains(.cnav2)) .init(&source.content) else .{ .declaration = &source.content },
            };
            break :blk out;
        } else &.{};
        return .{
            .gps = gps_publications,
            .inav = if (families.contains(.inav)) try publication.prepare(inav.Content, allocator, declarations.inav) else &.{},
            .d2 = if (families.contains(.d1d2)) try publication.prepare(d2.Prepared, allocator, declarations.d2) else &.{},
            .configuration = configuration,
            .cnav2_configuration = if (families.contains(.cnav2)) cnav2.configurationPage(&configuration) else null,
        };
    }
};
