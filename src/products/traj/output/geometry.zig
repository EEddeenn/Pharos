const std = @import("std");
const diagnostics = @import("base/diagnostics");
const coordinates = @import("domain/earth/coordinates");
const plan_read = @import("products/traj/input/read");
const guide = @import("products/traj/motion/geometry/guide");

pub const Error = diagnostics.InputError || error{InvalidSubdivisions};
pub const MapPosition = struct { latitude: f64, longitude: f64 };

pub const GuideOutline = struct {
    id: ?[]const u8,
    positions: ?[]const MapPosition,

    pub fn jsonStringify(self: GuideOutline, writer: anytype) !void {
        try writer.write(.{ .id = self.id, .whole = self.positions != null, .positions = self.positions });
    }
};

pub const GeometryDescription = struct { guides: []const GuideOutline };

/// Describe complete guides of a partial plan in degrees. The arena owns the returned data; text is not borrowed.
pub fn describeGeometry(arena: std.mem.Allocator, text: []const u8, max_steps_per_piece: usize, diags: *diagnostics.Diagnostics) Error!GeometryDescription {
    if (max_steps_per_piece == 0) return error.InvalidSubdivisions;
    const sketch = try plan_read.parseGeometry(arena, text, diags);
    const outlines = try arena.alloc(GuideOutline, sketch.guides.len);
    for (sketch.guides, outlines) |drawn, *outline| {
        outline.* = .{ .id = drawn.id, .positions = null };
        const whole = drawn.guide orelse continue;
        const shape = switch (try guide.build(arena, sketch.places, whole)) {
            .shape => |value| value,
            .fault => continue,
        };
        const points = try guide.outline(arena, shape, max_steps_per_piece);
        const positions = try arena.alloc(MapPosition, points.len);
        for (points, positions) |point, *position| {
            const lla = coordinates.ecefToLla(point);
            position.* = .{ .latitude = lla.latDeg(), .longitude = lla.lonDeg() };
        }
        outline.positions = positions;
    }
    return .{ .guides = outlines };
}
