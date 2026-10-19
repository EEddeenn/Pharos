//! A track over the WGS84 ellipsoid of constant geodesic curvature k (signed + to the right; a geodesic where it is
//! nothing): its points F by their length s over the ground, from the curve
//!
//!     F'' = k_n n + k (T x n),   n = D F / |D F|,   k_n = -(T . D T) / |D F|,   D = diag(1/a^2, 1/a^2, 1/b^2)
//!
//! with T = F' its unit tangent and k_n the ellipsoid's curvature along T. It is integrated by classical Runge-Kutta
//! steps of at most `longest_step_m` and at most a part `steps_per_radius` of the radius 1/|k|, each step's point
//! put back onto the ellipsoid and its tangent made a unit tangent there; between two nodes the track is the quintic
//! Hermite of F, T and F'' by length. Defined everywhere, the poles included.
const std = @import("std");
const shared = @import("shared");
const constants = shared.core.constants;
const Ecef = shared.core.coord.Ecef;
const Scalar = shared.trajectory.hermite.Scalar;

/// Over the Earth's curvature alone a step this long rounds a geodesic far below the sampler's micrometre: its
/// Clairaut constant keeps to about 1e-9 of its course over 10 000 km.
const longest_step_m = 10_000;
/// A turn's step is at most this part of its radius: its curvature then rounds by about 1e-8 of itself.
const steps_per_radius = 32;
/// The iterations a geodesic to a place takes at most.
const most_iterations = 32;
/// A geodesic to a place is found when it ends this near the place, in metres, or within the rounding of its steps.
const settled_m = 1e-9;
const rounding = 4 * std.math.floatEps(f64);

/// The ellipsoid's metric: a point x lies on it where the sum of metric[i] x[i]^2 is 1, its normal there along
/// metric x.
pub const metric = [3]f64{ 1 / (constants.wgs_axis_a * constants.wgs_axis_a), 1 / (constants.wgs_axis_a * constants.wgs_axis_a), 1 / (constants.wgs_axis_b * constants.wgs_axis_b) };

pub const Error = error{OutOfMemory};

/// A point of a track and its tangent there.
pub const Node = struct { point: Ecef, tangent: Ecef };

/// A point of a track with its first and second rates by length.
pub const Point = struct { point: Ecef, tangent: Ecef, curve: Ecef };

pub const Track = struct {
    curvature: f64,
    /// The length of every step but the last.
    step: f64,
    /// The nodes at 0, step, 2 step, ..., the last at `length`.
    nodes: []const Node,
    length: f64,

    pub fn at(self: *const Track, s: f64) Point {
        const last = self.nodes.len - 1;
        // At its ends the nodes themselves: the next segment begins at the very bits this one ends at.
        if (s <= 0 or s >= self.length) {
            const node = self.nodes[if (s <= 0) 0 else last];
            return .{ .point = node.point, .tangent = node.tangent, .curve = curve(node, self.curvature) };
        }
        const i: usize = @min(last - 1, @as(usize, @intFromFloat(@max(0, @floor(s / self.step)))));
        const s0 = @as(f64, @floatFromInt(i)) * self.step;
        const h = (if (i + 1 == last) self.length else s0 + self.step) - s0;
        const n0 = self.nodes[i];
        const n1 = self.nodes[i + 1];
        const c0 = curve(n0, self.curvature).toArray();
        const c1 = curve(n1, self.curvature).toArray();
        const p0 = n0.point.toArray();
        const p1 = n1.point.toArray();
        const t0 = n0.tangent.toArray();
        const t1 = n1.tangent.toArray();
        var out: [3][3]f64 = undefined;
        for (0..3) |axis| {
            const m = Scalar.motion(Scalar.quintic(p0[axis], t0[axis], c0[axis], p1[axis], t1[axis], c1[axis], h), h, (s - s0) / h);
            out[0][axis] = m.position;
            out[1][axis] = m.velocity;
            out[2][axis] = m.acceleration;
        }
        return .{ .point = .fromArray(out[0]), .tangent = .fromArray(out[1]), .curve = .fromArray(out[2]) };
    }

    pub fn end(self: *const Track) Node {
        return self.nodes[self.nodes.len - 1];
    }
};

/// The ellipsoid's normal at a point of it.
pub fn normal(point: Ecef) Ecef {
    return (Ecef{ .x = point.x * metric[0], .y = point.y * metric[1], .z = point.z * metric[2] }).unit();
}

/// F'' at a node.
pub fn curve(node: Node, curvature: f64) Ecef {
    const scaled: Ecef = .{ .x = node.point.x * metric[0], .y = node.point.y * metric[1], .z = node.point.z * metric[2] };
    const n = scaled.unit();
    const t = node.tangent;
    const across = t.x * t.x * metric[0] + t.y * t.y * metric[1] + t.z * t.z * metric[2];
    return n.scale(-across / scaled.norm()).add(t.cross(n).scale(curvature));
}

/// East and north where the normal is; on the axis, those of the meridian of longitude 0.
pub fn axes(n: Ecef) struct { east: Ecef, north: Ecef } {
    const flat = n.x * n.x + n.y * n.y;
    const east: Ecef = if (flat > 0) (Ecef{ .x = -n.y, .y = n.x, .z = 0 }).unit() else .{ .x = 0, .y = 1, .z = 0 };
    return .{ .east = east, .north = n.cross(east) };
}

/// The azimuth of a tangent at a point, clockwise from north, in (-pi, pi].
pub fn azimuth(node: Node) f64 {
    const frame = axes(normal(node.point));
    return std.math.atan2(node.tangent.dot(frame.east), node.tangent.dot(frame.north));
}

/// The unit tangent at a point on an azimuth.
pub fn heading(point: Ecef, angle: f64) Ecef {
    const frame = axes(normal(point));
    return frame.north.scale(@cos(angle)).add(frame.east.scale(@sin(angle)));
}

/// A point put onto the ellipsoid (along its ray from the centre, by far less than its rounding) and a tangent made
/// a unit tangent there.
fn settle(point: Ecef, tangent: Ecef) Node {
    const q = point.x * point.x * metric[0] + point.y * point.y * metric[1] + point.z * point.z * metric[2];
    const on = point.scale(1 / @sqrt(q));
    return .{ .point = on, .tangent = along(on, tangent) };
}

/// A direction made a unit tangent at a point of the ellipsoid.
pub fn along(point: Ecef, direction: Ecef) Ecef {
    const n = normal(point);
    return direction.sub(n.scale(direction.dot(n))).unit();
}

fn stepOf(node: Node, curvature: f64, h: f64) Node {
    const t1 = node.tangent;
    const a1 = curve(node, curvature);
    const t2 = t1.add(a1.scale(h / 2));
    const a2 = curve(.{ .point = node.point.add(t1.scale(h / 2)), .tangent = t2 }, curvature);
    const t3 = t1.add(a2.scale(h / 2));
    const a3 = curve(.{ .point = node.point.add(t2.scale(h / 2)), .tangent = t3 }, curvature);
    const t4 = t1.add(a3.scale(h));
    const a4 = curve(.{ .point = node.point.add(t3.scale(h)), .tangent = t4 }, curvature);
    const moved = t1.add(t2.scale(2)).add(t3.scale(2)).add(t4).scale(h / 6);
    const turned = a1.add(a2.scale(2)).add(a3.scale(2)).add(a4).scale(h / 6);
    return settle(node.point.add(moved), t1.add(turned));
}

/// The step of a track of this curvature.
fn stepFor(curvature: f64) f64 {
    return if (curvature == 0) longest_step_m else @min(longest_step_m, 1 / (@abs(curvature) * steps_per_radius));
}

/// The steps a track of this curvature and length takes: what its nodes cost before they are taken.
pub fn steps(curvature: f64, length: f64) f64 {
    return @ceil(length / stepFor(curvature));
}

/// The track from a node, of this curvature and length (above 0).
pub fn run(arena: std.mem.Allocator, from: Node, curvature: f64, length: f64) Error!Track {
    const h = stepFor(curvature);
    const count: usize = @intFromFloat(steps(curvature, length));
    const nodes = try arena.alloc(Node, count + 1);
    nodes[0] = from;
    for (1..count + 1) |i| {
        const s = @as(f64, @floatFromInt(i - 1)) * h;
        nodes[i] = stepOf(nodes[i - 1], curvature, if (i == count) length - s else h);
    }
    return .{ .curvature = curvature, .step = h, .nodes = nodes, .length = length };
}

/// The geodesic from one point of the ellipsoid to another, by Newton's method on its initial azimuth and its length
/// from the sphere's; null where it does not settle (the points nearly opposite, where geodesics part).
pub fn toward(arena: std.mem.Allocator, from: Ecef, to: Ecef) Error!?Track {
    const n0 = normal(from);
    const n1 = normal(to);
    const frame = axes(n0);
    const aim = n1.sub(n0.scale(n1.dot(n0)));
    var angle = std.math.atan2(aim.dot(frame.east), aim.dot(frame.north));
    var length = std.math.atan2(n0.cross(n1).norm(), n0.dot(n1)) * (from.norm() + to.norm()) / 2;
    const nudge: f64 = 1e-7;
    for (0..most_iterations) |_| {
        if (!(length > 0 and std.math.isFinite(length))) return null;
        const track = try run(arena, .{ .point = from, .tangent = heading(from, angle) }, 0, length);
        const last = track.end();
        const miss = to.sub(last.point);
        const settled = @max(settled_m, rounding * to.norm() * @sqrt(@as(f64, @floatFromInt(track.nodes.len))));
        if (miss.norm() <= settled) return track;
        const turned = (try run(arena, .{ .point = from, .tangent = heading(from, angle + nudge) }, 0, length)).end().point.sub(last.point).scale(1 / nudge);
        const across = normal(last.point).cross(last.tangent);
        // The miss in the plane at the track's end, against what a length and an angle move the end by.
        const m = [2][2]f64{ .{ last.tangent.dot(last.tangent), last.tangent.dot(turned) }, .{ across.dot(last.tangent), across.dot(turned) } };
        const r = [2]f64{ last.tangent.dot(miss), across.dot(miss) };
        const det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
        length += (r[0] * m[1][1] - m[0][1] * r[1]) / det;
        angle += (m[0][0] * r[1] - m[1][0] * r[0]) / det;
    }
    return null;
}

/// The track from a node, of this curvature, until its azimuth has turned by `angle` (signed as the curvature):
/// null where it does not within `most` steps.
pub fn turning(arena: std.mem.Allocator, from: Node, curvature: f64, angle: f64, most: usize) Error!?Track {
    const h = stepFor(curvature);
    var nodes: std.ArrayList(Node) = .empty;
    try nodes.append(arena, from);
    var turned: f64 = 0;
    var last = azimuth(from);
    while (nodes.items.len <= most) {
        const node = stepOf(nodes.items[nodes.items.len - 1], curvature, h);
        const now = azimuth(node);
        const change = turned + wrap(now - last);
        if ((change - angle) * std.math.sign(angle) >= 0) {
            // Within this step: the length where the azimuth reaches the angle, by halving on the step's Hermite.
            const before = nodes.items[nodes.items.len - 1];
            const piece: Track = .{ .curvature = curvature, .step = h, .nodes = &.{ before, node }, .length = h };
            var low: f64 = 0;
            var high: f64 = h;
            while (high - low > rounding * h) {
                const mid = (low + high) / 2;
                const p = piece.at(mid);
                if ((turned + wrap(azimuth(.{ .point = p.point, .tangent = p.tangent }) - last) - angle) * std.math.sign(angle) >= 0) high = mid else low = mid;
            }
            const s = @as(f64, @floatFromInt(nodes.items.len - 1)) * h;
            if (high > 0) try nodes.append(arena, stepOf(before, curvature, high));
            return .{ .curvature = curvature, .step = h, .nodes = nodes.items, .length = s + high };
        }
        try nodes.append(arena, node);
        turned = change;
        last = now;
    }
    return null;
}

/// An angle in (-pi, pi].
fn wrap(angle: f64) f64 {
    var a = @mod(angle + constants.pi, constants.two_pi) - constants.pi;
    if (a == -constants.pi) a = constants.pi;
    return a;
}
