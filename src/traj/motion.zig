//! A built segment's motion in time: its ground track (a track, or a part of a guide's path) run by the speed's
//! step, at the height of its own vertical (a straight's and a turn's: a quintic in the plan's altitude, the
//! geoid's height added over EGM96) or of its guide's places (an along's: their heights of least jerk by length).
//! The point is the ground's foot lifted along the ellipsoid's normal to that height.
const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const constants = core.constants;
const Ecef = core.coord.Ecef;
const trajectory = shared.trajectory;
const Scalar = trajectory.hermite.Scalar;
const frame = @import("frame.zig");
const Jet = frame.Jet;
const track = @import("track.zig");
const guide = @import("guide.zig");
const through = @import("through.zig");

pub const Error = error{OutOfMemory};

/// The speed's step from v0 to v1 over a duration T, its acceleration and jerk nothing at both ends: the length
/// s(t) = v0 t + (v1 - v0) T (5/2 u^4 - 3 u^5 + u^6), u = t / T.
pub const Timing = struct {
    v0: f64,
    v1: f64,
    duration: f64,

    pub fn length(self: Timing) f64 {
        return self.duration * (self.v0 + self.v1) / 2;
    }

    /// The length at a time from the segment's start, with its first and second rates; at the ends exactly.
    pub fn at(self: Timing, t: f64) Jet {
        if (t <= 0) return .{ .value = 0, .first = self.v0 };
        if (t >= self.duration) return .{ .value = self.length(), .first = self.v1 };
        const u = t / self.duration;
        const square = u * u;
        const step = self.v1 - self.v0;
        return .{
            .value = self.v0 * t + step * self.duration * square * square * (2.5 - 3 * u + square),
            .first = self.v0 + step * square * u * (10 - 15 * u + 6 * square),
            .second = step * 30 * square * (1 - 2 * u + square) / self.duration,
        };
    }

    /// The time at a length, by halving to the rounding of a time: the length grows with time.
    pub fn time(self: Timing, s: f64) f64 {
        var low: f64 = 0;
        var high = self.duration;
        while (true) {
            const mid = (low + high) / 2;
            if (mid <= low or mid >= high) return high;
            if (self.at(mid).value < s) low = mid else high = mid;
        }
    }
};

/// A height in time from (h0, c0, a0) to (h1, c1, 0) over a duration: their quintic Hermite; at the ends exactly.
pub const Vertical = struct {
    from: [3]f64,
    to: [2]f64,
    duration: f64,

    pub fn at(self: Vertical, t: f64) Jet {
        if (t <= 0) return .{ .value = self.from[0], .first = self.from[1], .second = self.from[2] };
        if (t >= self.duration) return .{ .value = self.to[0], .first = self.to[1] };
        const m = Scalar.motion(Scalar.quintic(self.from[0], self.from[1], self.from[2], self.to[0], self.to[1], 0, self.duration), self.duration, t / self.duration);
        return .{ .value = m.position, .first = m.velocity, .second = m.acceleration };
    }
};

/// Heights by length: their quintic Hermite between knots at the lengths of a guide's places, of least jerk.
pub const Profile = struct {
    lengths: []const f64,
    heights: []const f64,
    knots: []const through.Knot(1),

    /// The height at a length from the part's start, with its first and second rates by length.
    pub fn at(self: Profile, s: f64) Jet {
        const k = @min(self.lengths.len - 2, @max(1, std.sort.partitionPoint(f64, self.lengths, s, below)) - 1);
        const h = self.lengths[k + 1] - self.lengths[k];
        const m = Scalar.motion(Scalar.quintic(self.heights[k], self.knots[k].velocity[0], self.knots[k].acceleration[0], self.heights[k + 1], self.knots[k + 1].velocity[0], self.knots[k + 1].acceleration[0], h), h, (s - self.lengths[k]) / h);
        return .{ .value = m.position, .first = m.velocity, .second = m.acceleration };
    }
};

fn below(s: f64, length: f64) bool {
    return length <= s;
}

/// Which side of a joint a state is read on: the guide's piece, and the geoid's cell.
pub const Side = struct {
    piece: usize = 0,
    cell: ?*const core.geoid.Cell = null,
    /// Whether the piece, a leg, runs on before its start and past its end, into gentle corners' arcs.
    runs_on: [2]bool = .{ false, false },
};

pub const Run = struct {
    /// The time it begins.
    start: f64,
    timing: Timing,
    ground: union(enum) {
        track: track.Track,
        /// A part of a guide's path, from this ground length of it.
        guide: struct { shape: *const guide.Shape, from: f64 },
    },
    height: union(enum) {
        /// Its own vertical, in the plan's altitude: over EGM96 the geoid's height (by the side's cell) is added.
        own: Vertical,
        places: Profile,
    },

    /// The state at a time as a knot: a nothing written as 0, not -0.
    pub fn knot(self: *const Run, t: f64, side: Side) trajectory.Knot {
        const s = self.state(t, side);
        return .{ .t = t, .pos = s.pos, .vel = s.vel.add(zero), .acc = s.acc.add(zero) };
    }

    /// The ground's foot at a time, with its tangent and second rate by length; and the length's rates in time.
    pub fn foot(self: *const Run, t: f64, side: Side) struct { point: track.Point, length: Jet } {
        const s = self.timing.at(t - self.start);
        return .{ .point = switch (self.ground) {
            .track => |*tr| tr.at(s.value),
            .guide => |g| g.shape.ground(side.piece, g.from + s.value, side.runs_on),
        }, .length = s };
    }

    pub fn state(self: *const Run, t: f64, side: Side) trajectory.State {
        const f = self.foot(t, side);
        const s = f.length;
        const g = f.point;
        var point: frame.Vector = undefined;
        var scaled: frame.Vector = undefined;
        for (&point, &scaled, g.point.toArray(), g.tangent.toArray(), g.curve.toArray(), track.metric) |*p, *q, coordinate, tangent, curve, m| {
            p.* = .{ .value = coordinate, .first = tangent * s.first, .second = curve * s.first * s.first + tangent * s.second };
            q.* = p.scale(m);
        }
        const n = frame.unit(scaled);
        const height: Jet = switch (self.height) {
            .own => |v| blk: {
                const h = v.at(t - self.start);
                const cell = side.cell orelse break :blk h;
                const local = cell.surface(value(n));
                const n1: Ecef = .{ .x = n[0].first, .y = n[1].first, .z = n[2].first };
                const n2: Ecef = .{ .x = n[0].second, .y = n[1].second, .z = n[2].second };
                break :blk h.add(.{ .value = local.height, .first = local.rate(n1), .second = local.curvature(n1, n2) });
            },
            .places => |p| blk: {
                const h = p.at(s.value);
                break :blk .{ .value = h.value, .first = h.first * s.first, .second = h.second * s.first * s.first + h.first * s.second };
            },
        };
        var q: [3]Jet = undefined;
        for (&q, point, n) |*out, p, normal| out.* = p.add(height.mul(normal));
        return .{
            .pos = .{ .x = q[0].value, .y = q[1].value, .z = q[2].value },
            .vel = .{ .x = q[0].first, .y = q[1].first, .z = q[2].first },
            .acc = .{ .x = q[0].second, .y = q[1].second, .z = q[2].second },
            .jerk = .{ .x = 0, .y = 0, .z = 0 },
        };
    }
};

const zero: Ecef = .{ .x = 0, .y = 0, .z = 0 };

fn value(v: frame.Vector) Ecef {
    return .{ .x = v[0].value, .y = v[1].value, .z = v[2].value };
}

/// The geoid's grid where a normal points: its coordinates in grid steps of latitude from the south pole and of
/// longitude from 0 east, as the shared geoid takes them.
fn grid(n: Ecef) [2]f64 {
    const latitude = constants.rad2deg(std.math.atan2(n.z, @sqrt(n.x * n.x + n.y * n.y)));
    const longitude = @mod(constants.rad2deg(std.math.atan2(n.y, n.x)), 360.0);
    return .{ (std.math.clamp(latitude, -90.0, 90.0) + 90.0) / spacing_deg, longitude / spacing_deg };
}

const spacing_deg = 0.25;
/// The geoid's lines of latitude where its slope steps (its window of posts moves): from -89.5 to 89.5 degrees.
const first_line = 2;
const last_line = 718;
/// Nearer the pole than this, in grid steps from it, the geoid is its polar cap's alone, with no line.
const cap_steps = 0.5;
/// A line the track passes no farther off than the rounding of a coordinate is not crossed.
const margin = 4 * std.math.floatEps(f64) * 1440;

/// The ground lengths, between 0 and `length`, where a track crosses a line of the geoid's grid at which the geoid's
/// slope steps, or the edge of a polar cap; in order, each once.
pub fn crossings(arena: std.mem.Allocator, tr: *const track.Track) Error![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    for (0..tr.nodes.len - 1) |i| {
        const s0 = @as(f64, @floatFromInt(i)) * tr.step;
        const s1 = if (i + 2 == tr.nodes.len) tr.length else s0 + tr.step;
        // Each step cut where its latitude or longitude turns back, so that each piece of it is monotone in both.
        var cuts: [4]f64 = .{ s0, s1, s1, s1 };
        var count: usize = 2;
        for (0..2) |c| if (turning(tr, s0, s1, c)) |s| {
            cuts[count] = s;
            count += 1;
        };
        std.mem.sort(f64, cuts[0..count], {}, std.sort.asc(f64));
        for (cuts[0 .. count - 1], cuts[1..count]) |a, b| {
            if (!(b > a)) continue;
            const ga = grid(track.normal(tr.at(a).point));
            const gb = grid(track.normal(tr.at(b).point));
            for (0..2) |c| {
                // Longitude over the antimeridian goes on past 1440 or below 0.
                const far = if (c == 1) ga[1] + wrapSteps(gb[1] - ga[1]) else gb[c];
                const low = @min(ga[c], far);
                const high = @max(ga[c], far);
                var line = @ceil(low + margin);
                while (line <= high - margin) : (line += 1) {
                    if (c == 0 and (line < first_line or line > last_line)) continue;
                    const s = cross(tr, a, b, c, line, ga[c] < far);
                    if (c == 1 and !gridded(track.normal(tr.at(s).point))) continue;
                    if (s > 0 and s < tr.length) try out.append(arena, s);
                }
                // The polar caps' edges: inside them the geoid is the cap's, outside a cell's.
                if (c == 0) for ([_]f64{ cap_steps, 720 - cap_steps }) |edge| {
                    if (!(low + margin < edge and edge < high - margin)) continue;
                    const s = cross(tr, a, b, c, edge, ga[c] < far);
                    if (s > 0 and s < tr.length) try out.append(arena, s);
                };
            }
        }
    }
    // Found coordinate by coordinate (a falling one meets its lines in the opposite order): put in order, each once.
    std.mem.sort(f64, out.items, {}, std.sort.asc(f64));
    var kept: usize = 0;
    for (out.items) |s| {
        if (kept > 0 and !(s > out.items[kept - 1])) continue;
        out.items[kept] = s;
        kept += 1;
    }
    return out.items[0..kept];
}

fn wrapSteps(x: f64) f64 {
    return x - 1440 * @round(x / 1440);
}

/// Whether the geoid's grid, and so its lines of longitude, reaches where a normal points.
fn gridded(n: Ecef) bool {
    const y = grid(n)[0];
    return y > cap_steps and y < 720 - cap_steps;
}

/// Where in a step the latitude (c = 0) or the longitude (c = 1) turns back, if it does: where the tangent's
/// northward or eastward part changes sign.
fn turning(tr: *const track.Track, s0: f64, s1: f64, c: usize) ?f64 {
    const part = struct {
        fn of(t: *const track.Track, s: f64, which: usize) f64 {
            const p = t.at(s);
            const axes = track.axes(track.normal(p.point));
            return p.tangent.dot(if (which == 0) axes.north else axes.east);
        }
    }.of;
    const f0 = part(tr, s0, c);
    const f1 = part(tr, s1, c);
    if (!(f0 * f1 < 0)) return null;
    var low = s0;
    var high = s1;
    while (true) {
        const mid = (low + high) / 2;
        if (mid <= low or mid >= high) return mid;
        if ((part(tr, mid, c) < 0) == (f0 < 0)) low = mid else high = mid;
    }
}

/// The length in [a, b] where grid coordinate c reaches a line, by halving: it grows (or falls) over [a, b].
fn cross(tr: *const track.Track, a: f64, b: f64, c: usize, line: f64, rising: bool) f64 {
    const start = grid(track.normal(tr.at(a).point))[c];
    var low = a;
    var high = b;
    while (true) {
        const mid = (low + high) / 2;
        if (mid <= low or mid >= high) return mid;
        var at = grid(track.normal(tr.at(mid).point))[c];
        if (c == 1) at = start + wrapSteps(at - start);
        if ((at < line) == rising) low = mid else high = mid;
    }
}
