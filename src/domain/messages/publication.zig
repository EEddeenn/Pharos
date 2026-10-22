const std = @import("std");
const time = @import("domain/time/gps");
pub fn Publication(comptime Content: type) type {
    return struct {
        from: time.GpsTime,
        until: time.GpsTime,
        content: Content,

        pub fn at(publications: []const @This(), t: time.GpsTime) ?*const @This() {
            for (publications) |*publication| {
                if (t.lessThan(publication.from)) break;
                if (t.lessThan(publication.until)) return publication;
            }
            return null;
        }
    };
}

pub fn interval(from: time.GpsTime, until: time.GpsTime) bool {
    return from.lessThan(until);
}

pub fn follows(from: time.GpsTime, previous_until: ?time.GpsTime) bool {
    const end = previous_until orelse return true;
    return !from.lessThan(end);
}

pub fn prepare(comptime Prepared: type, allocator: std.mem.Allocator, raw: anytype) std.mem.Allocator.Error![]const Publication(Prepared) {
    const prepared = try allocator.alloc(Publication(Prepared), raw.len);
    for (raw, prepared) |*source, *result| {
        result.* = .{ .from = source.from, .until = source.until, .content = Prepared.init(&source.content) };
    }
    return prepared;
}
