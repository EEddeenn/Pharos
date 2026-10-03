const std = @import("std");
const time = @import("../core.zig").time;
const field = @import("../codec.zig").field;

pub const EncodingError = error{ValueOutOfRange} || field.Error;
pub const PrepareError = error{ OutOfMemory, InvalidPublication };
pub const Failure = struct { index: usize, reason: EncodingError };

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

pub fn ordered(publications: anytype) bool {
    var previous: ?time.GpsTime = null;
    for (publications) |*publication| {
        if (!interval(publication.from, publication.until)) return false;
        if (!follows(publication.from, previous)) return false;
        previous = publication.until;
    }
    return true;
}

pub fn prepare(comptime Prepared: type, allocator: std.mem.Allocator, raw: anytype, failure: *Failure) PrepareError![]const Publication(Prepared) {
    const prepared = try allocator.alloc(Publication(Prepared), raw.len);
    errdefer allocator.free(prepared);
    for (raw, prepared, 0..) |*publication, *result, index| {
        const content = Prepared.build(publication.content) catch |reason| {
            failure.* = .{ .index = index, .reason = reason };
            return error.InvalidPublication;
        };
        result.* = .{ .from = publication.from, .until = publication.until, .content = content };
    }
    return prepared;
}
