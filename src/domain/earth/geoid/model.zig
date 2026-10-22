const std = @import("std");
const manifest = @import("domain/earth/geoid/manifest");
const coordinates = @import("domain/earth/coordinates");
const angles = @import("base/math/angles");
const polynomial = @import("base/math/polynomial");
const geoid_grid = @import("domain/earth/geoid/grid");

const Lla = coordinates.Lla;
const Ecef = coordinates.Ecef;
const Grid = geoid_grid.Grid;

const blob = manifest.egm96_15.bytes;

const row_bytes = 4 + 2 * geoid_grid.columns;
const caps = blk: {
    @setEvalBranchQuota(200_000);
    break :blk .{ Cap.fit(0, 1), Cap.fit(geoid_grid.rows - 1, geoid_grid.rows - 2) };
};

comptime {
    std.debug.assert(blob.len == geoid_grid.rows * row_bytes);
}

pub const Local = struct {
    height: f64,
    gradient: Ecef,
    hessian: [3][3]f64,

    pub fn rate(self: Local, normal_dot: Ecef) f64 {
        return self.gradient.dot(normal_dot);
    }

    pub fn curvature(self: Local, normal_dot: Ecef, normal_ddot: Ecef) f64 {
        const d = normal_dot.toArray();
        var result = self.gradient.dot(normal_ddot);
        for (self.hessian, 0..) |row, i| {
            for (row, 0..) |v, j| result += v * d[i] * d[j];
        }
        return result;
    }

    fn cartesian(normal: Ecef, value: f64, gradient: Ecef, hessian: [3][3]f64) Local {
        const n = normal.toArray();
        const ng = normal.dot(gradient);
        var hn: [3]f64 = .{ 0, 0, 0 };
        for (hessian, 0..) |row, i| {
            for (row, 0..) |v, j| hn[i] += v * n[j];
        }
        const nhn = normal.dot(Ecef.fromArray(hn));
        var result: Local = .{ .height = value, .gradient = gradient.sub(normal.scale(ng)), .hessian = undefined };
        for (&result.hessian, 0..) |*row, i| {
            for (row, 0..) |*v, j| {
                v.* = hessian[i][j] - n[i] * hn[j] - hn[i] * n[j] + (nhn + ng) * n[i] * n[j];
                if (i == j) v.* -= ng;
            }
        }
        return result;
    }

    fn angular(normal: Ecef, s: Angular) Local {
        const r = @sqrt(normal.x * normal.x + normal.y * normal.y);
        const east: Ecef = .{ .x = -normal.y / r, .y = normal.x / r, .z = 0 };
        const north = normal.cross(east);
        const nn = north.toArray();
        const ee = east.toArray();
        const mixed = (s.d_lat_lon + normal.z / r * s.d_lon) / r;
        const parallel = s.d_lon_lon / (r * r) - normal.z / r * s.d_lat;
        var result: Local = .{
            .height = s.height,
            .gradient = north.scale(s.d_lat).add(east.scale(s.d_lon / r)),
            .hessian = undefined,
        };
        for (&result.hessian, 0..) |*row, i| {
            for (row, 0..) |*v, j| {
                v.* = s.d_lat_lat * nn[i] * nn[j] + mixed * (nn[i] * ee[j] + ee[i] * nn[j]) + parallel * ee[i] * ee[j];
            }
        }
        return result;
    }

    fn blend(p: Local, s: Local, q: Local) Local {
        const w = blendWeight(f64, Float, 0, q.height);
        const wq = blendWeight(f64, Float, 1, q.height);
        const wqq = blendWeight(f64, Float, 2, q.height);
        const difference = s.height - p.height;
        const gradient_difference = s.gradient.sub(p.gradient);
        const g = q.gradient.toArray();
        const d = gradient_difference.toArray();
        var result: Local = .{
            .height = p.height + w * difference,
            .gradient = p.gradient.add(gradient_difference.scale(w)).add(q.gradient.scale(difference * wq)),
            .hessian = undefined,
        };
        for (&result.hessian, 0..) |*row, i| {
            for (row, 0..) |*v, j| {
                v.* = p.hessian[i][j] + w * (s.hessian[i][j] - p.hessian[i][j]) +
                    wq * (g[i] * d[j] + d[i] * g[j]) + difference * (wq * q.hessian[i][j] + wqq * g[i] * g[j]);
            }
        }
        return result;
    }
};

const Angular = struct {
    height: f64,
    d_lat: f64,
    d_lon: f64,
    d_lat_lat: f64,
    d_lat_lon: f64,
    d_lon_lon: f64,
};

pub const Cell = struct {
    south: usize,
    west: i64,
    posts: [4][4]f64,

    pub fn at(lat_rad: f64, lon_rad: f64) Cell {
        const g = Grid.of(lat_rad, lon_rad);
        var posts: [4][4]f64 = undefined;
        for (&posts, 0..) |*row, k| row.* = windowRow(geoid_grid.rows - 1 - (g.south + k), g.west);
        return .{ .south = g.south, .west = g.west, .posts = posts };
    }

    pub fn contains(self: *const Cell, lat_rad: f64, lon_rad: f64) bool {
        const g = Grid.of(lat_rad, lon_rad);
        return g.south == self.south and g.west == self.west;
    }

    pub fn height(self: *const Cell, lat_rad: f64, lon_rad: f64) f64 {
        const normal = normalAt(lat_rad, lon_rad);
        const q = normal.x * normal.x + normal.y * normal.y;
        if (q <= geoid_grid.cap_inner_squared) return Cap.at(normal).height(f64, Float, normal.toArray());
        return Evaluator(f64, Float).heightAt(self, normal.toArray(), q, lat_rad, lon_rad);
    }

    pub fn surface(self: *const Cell, normal: Ecef) Local {
        const q = normal.x * normal.x + normal.y * normal.y;
        if (q <= geoid_grid.cap_inner_squared) return Cap.at(normal).surface(normal);
        return self.surfaceAt(normal, q, std.math.atan2(normal.z, @sqrt(q)), std.math.atan2(normal.y, normal.x));
    }

    fn surfaceAt(self: *const Cell, normal: Ecef, q: f64, lat_rad: f64, lon_rad: f64) Local {
        const s = Local.angular(normal, self.angular(lat_rad, lon_rad));
        if (q >= geoid_grid.cap_outer_squared) return s;
        const p = Cap.at(normal).surface(normal);
        const radial = Local.cartesian(normal, q, .{ .x = 2 * normal.x, .y = 2 * normal.y, .z = 0 }, .{
            .{ 2, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 0 },
        });
        return p.blend(s, radial);
    }

    fn angular(self: *const Cell, lat_rad: f64, lon_rad: f64) Angular {
        const g = Grid.of(lat_rad, lon_rad);
        var value: [4]f64 = undefined;
        var slope: [4]f64 = undefined;
        var curvature: [4]f64 = undefined;
        // The longitude from the window's first post, the nearer way round the meridian (a point read from a cell
        // it borders, across longitude 0, is a step or two from the window, not 1438).
        const dx = g.x - @as(f64, @floatFromInt(self.west));
        const local = dx - geoid_grid.columns * @round((dx - 1.5) / geoid_grid.columns);
        for (self.posts, 0..) |row, k| {
            const s = spline(row, local);
            value[k] = s.value;
            slope[k] = s.slope;
            curvature[k] = s.curvature;
        }
        const y = g.y - @as(f64, @floatFromInt(self.south));
        const along = spline(value, y);
        const along_slope = spline(slope, y);
        const k = 1.0 / angles.deg2rad(geoid_grid.spacing_deg);
        return .{
            .height = along.value,
            .d_lat = along.slope * k,
            .d_lon = along_slope.value * k,
            .d_lat_lat = along.curvature * k * k,
            .d_lat_lon = along_slope.slope * k * k,
            .d_lon_lon = spline(curvature, y).value * k * k,
        };
    }
};

const Cap = struct {
    c: f64,
    a: f64,
    b: f64,
    d: f64,
    e: f64,
    f: f64,

    fn at(normal: Ecef) Cap {
        return if (normal.z >= 0) caps[0] else caps[1];
    }

    fn fit(pole: usize, ring: usize) Cap {
        const c = @as(f64, @floatFromInt(std.mem.readInt(i32, blob[pole * row_bytes ..][0..4], .little))) / 1000;
        const row = blob[ring * row_bytes ..][0..row_bytes];
        var mm: i64 = std.mem.readInt(i32, row[0..4], .little);
        var sum: f64 = 0;
        var a: f64 = 0;
        var b: f64 = 0;
        var e: f64 = 0;
        var f: f64 = 0;
        for (0..geoid_grid.columns) |j| {
            if (j > 0) mm += step(row, j);
            const value = @as(f64, @floatFromInt(mm)) / 1000 - c;
            const lon = angles.two_pi * @as(f64, @floatFromInt(j)) / geoid_grid.columns;
            sum += value;
            a += value * @cos(lon);
            b += value * @sin(lon);
            e += value * @cos(2 * lon);
            f += value * @sin(2 * lon);
        }
        const r = @sin(angles.deg2rad(geoid_grid.spacing_deg));
        return .{
            .c = c,
            .a = 2 * a / (geoid_grid.columns * r),
            .b = 2 * b / (geoid_grid.columns * r),
            .d = sum / (geoid_grid.columns * r * r),
            .e = 2 * e / (geoid_grid.columns * r * r),
            .f = 2 * f / (geoid_grid.columns * r * r),
        };
    }

    fn height(self: Cap, comptime N: type, comptime A: type, normal: [3]N) N {
        const x = normal[0];
        const y = normal[1];
        return A.add(A.add(A.add(A.add(A.add(A.constant(self.c), A.scale(x, self.a)), A.scale(y, self.b)), A.scale(A.mul(x, x), self.d + self.e)), A.scale(A.mul(x, y), 2 * self.f)), A.scale(A.mul(y, y), self.d - self.e));
    }

    fn surface(self: Cap, normal: Ecef) Local {
        const x = normal.x;
        const y = normal.y;
        const value = self.height(f64, Float, normal.toArray());
        return Local.cartesian(normal, value, .{
            .x = self.a + 2 * (self.d + self.e) * x + 2 * self.f * y,
            .y = self.b + 2 * self.f * x + 2 * (self.d - self.e) * y,
            .z = 0,
        }, .{
            .{ 2 * (self.d + self.e), 2 * self.f, 0 },
            .{ 2 * self.f, 2 * (self.d - self.e), 0 },
            .{ 0, 0, 0 },
        });
    }
};

const Spline = struct { value: f64, slope: f64, curvature: f64 };

const Float = struct {
    pub fn constant(number: f64) f64 {
        return number;
    }
    pub fn value(number: f64) f64 {
        return number;
    }
    pub fn failed() f64 {
        return std.math.nan(f64);
    }
    pub fn add(a: f64, b: f64) f64 {
        return a + b;
    }
    pub fn sub(a: f64, b: f64) f64 {
        return a - b;
    }
    pub fn mul(a: f64, b: f64) f64 {
        return a * b;
    }
    pub fn scale(a: f64, factor: f64) f64 {
        return a * factor;
    }
    pub fn sqrt(a: f64) f64 {
        return @sqrt(a);
    }
    pub fn atan2(y: f64, x: f64) f64 {
        return std.math.atan2(y, x);
    }
};

pub fn height(lat_rad: f64, lon_rad: f64) f64 {
    return Cell.at(lat_rad, lon_rad).height(lat_rad, lon_rad);
}

pub fn surface(normal: Ecef) Local {
    const q = normal.x * normal.x + normal.y * normal.y;
    if (q <= geoid_grid.cap_inner_squared) return Cap.at(normal).surface(normal);
    const lat = std.math.atan2(normal.z, @sqrt(q));
    const lon = std.math.atan2(normal.y, normal.x);
    return Cell.at(lat, lon).surfaceAt(normal, q, lat, lon);
}

pub fn altitude(p: Lla) f64 {
    return p.height_m - height(p.lat_rad, p.lon_rad);
}

pub fn lla(lat_rad: f64, lon_rad: f64, altitude_m: f64) Lla {
    return .{ .lat_rad = lat_rad, .lon_rad = lon_rad, .height_m = altitude_m + height(lat_rad, lon_rad) };
}

pub fn Evaluator(comptime N: type, comptime A: type) type {
    return struct {
        pub fn height(normal: [3]N) N {
            const q = A.add(A.mul(normal[0], normal[0]), A.mul(normal[1], normal[1]));
            if (!std.math.isFinite(A.value(q))) return A.failed();
            if (A.value(q) <= geoid_grid.cap_inner_squared) return cap(normal).height(N, A, normal);
            const latitude = A.atan2(normal[2], A.sqrt(q));
            const longitude = A.atan2(normal[1], normal[0]);
            const cell = Cell.at(A.value(latitude), A.value(longitude));
            return heightAt(&cell, normal, q, latitude, longitude);
        }

        fn heightAt(cell: *const Cell, normal: [3]N, q: N, latitude: N, longitude: N) N {
            const gridded = gridHeight(cell, latitude, longitude);
            if (A.value(q) >= geoid_grid.cap_outer_squared) return gridded;
            const polar = cap(normal).height(N, A, normal);
            return A.add(polar, A.mul(blendWeight(N, A, 0, q), A.sub(gridded, polar)));
        }

        fn gridHeight(cell: *const Cell, latitude: N, longitude: N) N {
            const lat = A.value(latitude);
            const lon = A.value(longitude);
            const location = Grid.of(lat, lon);
            const k = angles.rad2deg(1) / geoid_grid.spacing_deg;
            const x = A.add(A.constant(location.x - @as(f64, @floatFromInt(cell.west))), A.scale(A.sub(longitude, A.constant(lon)), k));
            const y = A.add(A.constant(location.y - @as(f64, @floatFromInt(cell.south))), A.scale(A.sub(latitude, A.constant(lat)), k));
            const index = splineIndex(A.value(x));
            const fraction = A.sub(x, A.constant(@floatFromInt(index)));
            var across: [4]N = undefined;
            for (&across, cell.posts) |*out, row| {
                const coefficients = splineCoefficients(f64, Float, row, index);
                var numeric: [4]N = undefined;
                for (&numeric, coefficients) |*value, coefficient| value.* = A.constant(coefficient);
                out.* = polynomial.evaluate(N, A, 0, numeric, fraction);
            }
            const along_index = splineIndex(A.value(y));
            return polynomial.evaluate(N, A, 0, splineCoefficients(N, A, across, along_index), A.sub(y, A.constant(@floatFromInt(along_index))));
        }

        fn cap(normal: [3]N) Cap {
            return if (A.value(normal[2]) >= 0) caps[0] else caps[1];
        }
    };
}

fn normalAt(lat_rad: f64, lon_rad: f64) Ecef {
    if (@abs(lat_rad) == angles.pi / 2) return .{ .x = 0, .y = 0, .z = std.math.copysign(@as(f64, 1), lat_rad) };
    const cp = @cos(lat_rad);
    return .{ .x = cp * @cos(lon_rad), .y = cp * @sin(lon_rad), .z = @sin(lat_rad) };
}

fn windowRow(r: usize, west: i64) [4]f64 {
    const row = blob[r * row_bytes ..][0..row_bytes];
    const first: usize = @intCast(@mod(west, geoid_grid.columns));
    var mm: i64 = std.mem.readInt(i32, row[0..4], .little);
    if (first <= geoid_grid.columns / 2) {
        for (1..first + 1) |c| mm += step(row, c);
    } else {
        var c: usize = geoid_grid.columns;
        while (c > first) : (c -= 1) mm -= step(row, c);
    }
    var posts: [4]f64 = undefined;
    for (&posts, 0..) |*p, k| {
        if (k > 0) mm += step(row, (first + k - 1) % geoid_grid.columns + 1);
        p.* = @as(f64, @floatFromInt(mm)) / 1000.0;
    }
    return posts;
}

fn step(row: *const [row_bytes]u8, c: usize) i64 {
    return std.mem.readInt(i16, row[4 + 2 * (c - 1) ..][0..2], .little);
}

fn spline(y: [4]f64, x: f64) Spline {
    const index = splineIndex(x);
    const coefficients = splineCoefficients(f64, Float, y, index);
    const t = x - @as(f64, @floatFromInt(index));
    return .{
        .value = polynomial.evaluate(f64, Float, 0, coefficients, t),
        .slope = polynomial.evaluate(f64, Float, 1, coefficients, t),
        .curvature = polynomial.evaluate(f64, Float, 2, coefficients, t),
    };
}

fn splineIndex(x: f64) usize {
    return @intFromFloat(@min(@floor(x), 2));
}

fn splineCoefficients(comptime T: type, comptime A: type, y: [4]T, index: usize) [4]T {
    var m1 = A.scale(A.add(A.sub(y[2], A.scale(y[1], 2)), y[0]), 1.5);
    const m2 = A.scale(A.sub(A.scale(A.add(A.sub(y[3], A.scale(y[2], 2)), y[1]), 3), A.scale(m1, 0.5)), 1.0 / 1.875);
    m1 = A.sub(m1, A.scale(m2, 0.25));
    const second = [_]T{ A.constant(0), m1, m2, A.constant(0) };
    const b = A.sub(A.sub(A.sub(y[index + 1], y[index]), A.scale(second[index], 1.0 / 3.0)), A.scale(second[index + 1], 1.0 / 6.0));
    return .{ y[index], b, A.scale(second[index], 0.5), A.scale(A.sub(second[index + 1], second[index]), 1.0 / 6.0) };
}

fn blendWeight(comptime N: type, comptime A: type, comptime order: usize, q: N) N {
    const width = geoid_grid.cap_outer_squared - geoid_grid.cap_inner_squared;
    const u = A.scale(A.sub(q, A.constant(geoid_grid.cap_inner_squared)), 1 / width);
    const coefficients = [_]N{ A.constant(0), A.constant(0), A.constant(0), A.constant(10), A.constant(-15), A.constant(6) };
    var result = polynomial.evaluate(N, A, order, coefficients, u);
    inline for (0..order) |_| result = A.scale(result, 1 / width);
    return result;
}
