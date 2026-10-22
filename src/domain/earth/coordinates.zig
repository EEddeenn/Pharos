const std = @import("std");
const angles = @import("base/math/angles");
const earth_constants = @import("domain/earth/constants");

pub const Lla = struct {
    lat_rad: f64,
    lon_rad: f64,
    height_m: f64,

    pub fn latDeg(self: Lla) f64 {
        return angles.rad2deg(self.lat_rad);
    }

    pub fn lonDeg(self: Lla) f64 {
        return angles.rad2deg(self.lon_rad);
    }
};

pub const Ecef = Cartesian(f64);

pub const Enu = struct { east: f64, north: f64, up: f64 };

const SpeedCourse = struct { speed: f64, course_rad: f64 };

pub const ElAz = struct { el_rad: f64, az_rad: f64 };

pub const EnuFrame = struct {
    rows: [3][3]f64,

    pub fn at(p: Lla) EnuFrame {
        const sl = @sin(p.lon_rad);
        const cl = @cos(p.lon_rad);
        const sp = @sin(p.lat_rad);
        const cp = @cos(p.lat_rad);
        return .{ .rows = .{
            .{ -sl, cl, 0 },
            .{ -sp * cl, -sp * sl, cp },
            .{ cp * cl, cp * sl, sp },
        } };
    }

    pub fn toEnu(self: EnuFrame, v: Ecef) Enu {
        const r = self.rows;
        return .{
            .east = r[0][0] * v.x + r[0][1] * v.y + r[0][2] * v.z,
            .north = r[1][0] * v.x + r[1][1] * v.y + r[1][2] * v.z,
            .up = r[2][0] * v.x + r[2][1] * v.y + r[2][2] * v.z,
        };
    }

    pub fn elAz(self: EnuFrame, los: Ecef) ElAz {
        const e = self.toEnu(los);
        const h = @sqrt(e.east * e.east + e.north * e.north);
        var az = std.math.atan2(e.east, e.north);
        if (az < 0) az += angles.two_pi;
        return .{ .el_rad = std.math.atan2(e.up, h), .az_rad = az };
    }
};

const axis_threshold_m = 1e-10;

pub fn Cartesian(comptime Number: type) type {
    return struct {
        x: Number,
        y: Number,
        z: Number,

        const Self = @This();

        pub fn fromArray(a: [3]Number) Self {
            return .{ .x = a[0], .y = a[1], .z = a[2] };
        }

        pub fn toArray(self: Self) [3]Number {
            return .{ self.x, self.y, self.z };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
        }

        pub fn scale(a: Self, k: Number) Self {
            return .{ .x = a.x * k, .y = a.y * k, .z = a.z * k };
        }

        pub fn divide(a: Self, d: Number) Self {
            return .{ .x = a.x / d, .y = a.y / d, .z = a.z / d };
        }

        pub fn dot(a: Self, b: Self) Number {
            return a.x * b.x + a.y * b.y + a.z * b.z;
        }

        pub fn norm(a: Self) Number {
            return @sqrt(a.dot(a));
        }

        pub fn cross(a: Self, b: Self) Self {
            return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
        }

        pub fn unit(a: Self) Self {
            return a.divide(a.norm());
        }

        pub fn rotateZ(v: Self, theta: Number) Self {
            const c: Number = @cos(theta);
            const s: Number = @sin(theta);
            return .{ .x = v.x * c + v.y * s, .y = -v.x * s + v.y * c, .z = v.z };
        }
    };
}

pub fn llaToEcef(p: Lla) Ecef {
    const sin_lat = @sin(p.lat_rad);
    const cos_lat = @cos(p.lat_rad);
    const n = earth_constants.wgs_axis_a / @sqrt(1.0 - earth_constants.wgs_e1_sqr * sin_lat * sin_lat);
    return .{
        .x = (n + p.height_m) * cos_lat * @cos(p.lon_rad),
        .y = (n + p.height_m) * cos_lat * @sin(p.lon_rad),
        .z = (n * (1.0 - earth_constants.wgs_e1_sqr) + p.height_m) * sin_lat,
    };
}

pub fn ecefToLla(e: Ecef) Lla {
    const a = earth_constants.wgs_axis_a;
    const b = earth_constants.wgs_axis_b;
    const e2 = earth_constants.wgs_e1_sqr;
    const p = @sqrt(e.x * e.x + e.y * e.y);
    if (p < axis_threshold_m) {
        return .{ .lat_rad = std.math.copysign(angles.pi / 2.0, e.z), .lon_rad = 0, .height_m = @abs(e.z) - b };
    }
    const theta = std.math.atan(e.z * a / (p * b));
    const st = @sin(theta);
    const ct = @cos(theta);
    const start = std.math.atan((e.z + earth_constants.wgs_e2_sqr * b * st * st * st) / (p - e2 * a * ct * ct * ct));
    const s0 = @sin(start);
    const c0 = @cos(start);
    const w2 = 1.0 - e2 * s0 * s0;
    const n = a / @sqrt(w2);
    const f = p * s0 - e.z * c0 - e2 * n * s0 * c0;
    const df = p * c0 + e.z * s0 - e2 * n * (e2 * s0 * c0 * s0 * c0 / w2 + c0 * c0 - s0 * s0);
    const lat = start - f / df;
    const s = @sin(lat);
    const c = @cos(lat);
    return .{ .lat_rad = lat, .lon_rad = std.math.atan2(e.y, e.x), .height_m = p * c + e.z * s - a * @sqrt(1.0 - e2 * s * s) };
}

fn speedCourseFromEnu(v: Enu) SpeedCourse {
    var course = std.math.atan2(v.east, v.north);
    if (course < 0) course += angles.two_pi;
    return .{ .speed = @sqrt(v.east * v.east + v.north * v.north), .course_rad = course };
}
