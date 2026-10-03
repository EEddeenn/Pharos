const std = @import("std");
const core = @import("shared").core;
const model = @import("model.zig");
const Vector = model.Vector;

pub fn toEcef(given: model.Position, altitude: model.Altitude) Vector {
    const lat = core.constants.deg2rad(given.latitude);
    const lon = core.constants.deg2rad(given.longitude);
    const lla: core.coord.Lla = switch (altitude) {
        .egm96 => core.geoid.lla(lat, lon, given.altitude),
        .ellipsoid => .{ .lat_rad = lat, .lon_rad = lon, .height_m = given.altitude },
    };
    return core.coord.llaToEcef(lla);
}

pub const CurveState = struct { position: Vector, derivative: Vector, second_derivative: Vector };

pub fn curve(geometry: model.Geometry, index: usize, parameter: f64) CurveState {
    const path = geometry.curves[index];
    const segments = switch (path.kind) {
        .bezier => (path.points.len - 1) / 3,
        .polyline => path.points.len - 1,
    };
    const count: f64 = @floatFromInt(segments);
    const t = std.math.clamp(parameter, 0, 1) * count;
    const piece = @min(@as(usize, @intFromFloat(@floor(t))), segments - 1);
    const u = t - @as(f64, @floatFromInt(piece));
    const start = switch (path.kind) {
        .bezier => piece * 3,
        .polyline => piece,
    };
    const a = geometry.points[path.points[start]].ecef;
    const b = geometry.points[path.points[start + 1]].ecef;
    if (path.kind == .polyline) return .{
        .position = a.add(b.sub(a).scale(u)),
        .derivative = b.sub(a).scale(count),
        .second_derivative = .{ .x = 0, .y = 0, .z = 0 },
    };
    const c = geometry.points[path.points[start + 2]].ecef;
    const d = geometry.points[path.points[start + 3]].ecef;
    const v = 1 - u;
    return .{
        .position = a.scale(v * v * v).add(b.scale(3 * v * v * u)).add(c.scale(3 * v * u * u)).add(d.scale(u * u * u)),
        .derivative = b.sub(a).scale(3 * v * v * count).add(c.sub(b).scale(6 * v * u * count)).add(d.sub(c).scale(3 * u * u * count)),
        .second_derivative = c.sub(b.scale(2)).add(a).scale(6 * v * count * count).add(d.sub(c.scale(2)).add(b).scale(6 * u * count * count)),
    };
}

pub const Plane = struct {
    origin: Vector,
    frame: core.coord.EnuFrame,

    pub fn at(origin: Vector) Plane {
        return .{ .origin = origin, .frame = .at(core.coord.ecefToLla(origin)) };
    }

    pub fn project(self: Plane, value: Vector) [2]f64 {
        const enu = self.frame.toEnu(value.sub(self.origin));
        return .{ enu.east, enu.north };
    }

    pub fn unproject(self: Plane, value: [2]f64) Vector {
        const east = Vector.fromArray(self.frame.rows[0]);
        const north = Vector.fromArray(self.frame.rows[1]);
        return self.origin.add(east.scale(value[0])).add(north.scale(value[1]));
    }
};

pub fn polygonPlane(points: []const model.Point, indices: []const usize) Plane {
    var sum: Vector = .{ .x = 0, .y = 0, .z = 0 };
    for (indices) |index| sum = sum.add(points[index].ecef);
    return .at(sum.divide(@floatFromInt(indices.len)));
}

fn cross(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

pub fn polygonValid(points: []const model.Point, indices: []const usize) bool {
    if (indices.len < 3) return false;
    const plane = polygonPlane(points, indices);
    var sign: f64 = 0;
    for (indices, 0..) |index, i| {
        for (indices[0..i]) |previous| if (points[previous].ecef.sub(points[index].ecef).norm() <= 1e-6) return false;
        const a = plane.project(points[index].ecef);
        const b = plane.project(points[indices[(i + 1) % indices.len]].ecef);
        const distance = std.math.hypot(b[0] - a[0], b[1] - a[1]);
        if (!(distance > 1e-6)) return false;
        for (indices, 0..) |other, j| {
            if (j == i or j == (i + 1) % indices.len) continue;
            const z = cross(a, b, plane.project(points[other].ecef));
            if (!std.math.isFinite(z)) return false;
            if (@abs(z) <= 1e-8 * distance) continue;
            if (sign == 0) sign = z;
            if ((sign > 0) != (z > 0)) return false;
        }
    }
    return sign != 0;
}
