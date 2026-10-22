//! A guide's path, in ECEF: a polyline's legs, chords from place to place, each corner rounded by an arc of the
//! guide's radius in the plane of the corner's two legs and tangent to both; or a Bezier's cubic pieces as they are.
//! Its ground track is the path's foot on the ellipsoid, by its length s over the ground: eight-point
//! Gauss-Legendre over each piece's parts, a part halved until its length agrees with its halves', and, for the
//! parameter of a length, Newton's method kept within its part.
const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const model = @import("products/traj/input/model");
const frame = @import("products/traj/motion/geometry/frame");
const track = @import("products/traj/motion/geometry/track");
const measure = @import("products/traj/limits/measure");
const angles = @import("base/math/angles");

const Ecef = coordinates.Ecef;

/// A part's length is settled when its halves' agree with it to a nanometre, or to its own rounding.
const settled_m = 1e-9;
/// A piece takes this many parts at most, each halved this many times at most: the hardest a caller draws (a
/// cusp, a tip of centimetres) takes some 30 parts; one that takes more passes so near the geocentre that its foot
/// is no longer one point of the ellipsoid.
const most_parts = 1024;
const most_halvings = 40;

/// A piece of the path by its parameter u from 0 to 1.
pub const Piece = union(enum) {
    line: struct { from: Ecef, to: Ecef },
    /// An arc about `centre` from `centre + radius out` turning towards `-out`, its first direction `along`.
    arc: struct { centre: Ecef, out: Ecef, along: Ecef, radius: f64, angle: f64 },
    cubic: [4]Ecef,

    /// The direction its foot on the ellipsoid moves in at u.
    pub fn direction(self: Piece, u: f64) Ecef {
        return foot(self.at(u))[1].unit();
    }

    /// Its foot's speed over the ground by u, and that speed's rate.
    pub fn speed(self: Piece, u: f64) [2]f64 {
        const q = self.at(u);
        return track.footSpeed(q[0], q[1], q[2]);
    }

    /// The point at u, with its first and second rates by u.
    fn at(self: Piece, u: f64) [3]Ecef {
        return switch (self) {
            .line => |l| .{ l.from.add(l.to.sub(l.from).scale(u)), l.to.sub(l.from), .{ .x = 0, .y = 0, .z = 0 } },
            .arc => |a| blk: {
                const phi = a.angle * u;
                const c = @cos(phi);
                const s = @sin(phi);
                const radial = a.out.scale(c).add(a.along.scale(s));
                break :blk .{ a.centre.add(radial.scale(a.radius)), a.along.scale(c).sub(a.out.scale(s)).scale(a.radius * a.angle), radial.scale(-a.radius * a.angle * a.angle) };
            },
            .cubic => |p| blk: {
                const v = 1 - u;
                const point = p[0].scale(v * v * v).add(p[1].scale(3 * v * v * u)).add(p[2].scale(3 * v * u * u)).add(p[3].scale(u * u * u));
                const first = p[1].sub(p[0]).scale(3 * v * v).add(p[2].sub(p[1]).scale(6 * v * u)).add(p[3].sub(p[2]).scale(3 * u * u));
                const second = p[2].sub(p[1].scale(2)).add(p[0]).scale(6 * v).add(p[3].sub(p[2].scale(2)).add(p[1]).scale(6 * u));
                break :blk .{ point, first, second };
            },
        };
    }
};

/// The end of a part of a piece: its parameter, and the ground length to it from the piece's start.
const Part = struct { u: f64, s: f64 };

pub const Shape = struct {
    pieces: []const Piece,
    /// The ground length where each piece begins, and where the path ends.
    starts: []const f64,
    /// For each piece, the ends of its parts in order, the last at its end.
    parts: []const []const Part,
    /// For each piece, the ground length from its start to its middle: an arc's is where its corner's place is.
    middles: []const f64,
    /// The ground length where the path passes each place of the guide, by the place's position in it; a Bezier's
    /// control places, which it does not pass, are 0.
    places: []const f64,

    /// The piece that a length lies on: the last that begins at or before it.
    pub fn piece(self: *const Shape, s: f64) usize {
        return @max(1, std.sort.partitionPoint(f64, self.starts[0..self.pieces.len], s, before)) - 1;
    }

    /// The foot at ground length s on piece k, with its first and second rates by that length. A leg that runs on
    /// (`runs_on`, before its start and past its end), as an along runs a corner too gentle to round, goes on along
    /// its chord into the corner's arc, evenly in its parameter, to reach the corner's place at the arc's middle.
    pub fn ground(self: *const Shape, k: usize, s: f64, runs_on: [2]bool) track.Point {
        const piece_ = self.pieces[k];
        const past: ?usize = if (runs_on[1] and s > self.starts[k + 1]) k + 1 else if (runs_on[0] and s < self.starts[k]) k - 1 else null;
        if (past) |arc| {
            const corner = self.pieces[arc].arc;
            const reach = corner.radius * @tan(corner.angle / 2) / piece_.line.to.sub(piece_.line.from).norm();
            const ahead = arc > k;
            const end = self.starts[@max(arc, k)];
            const rate = (if (ahead) reach else -reach) / (self.starts[arc] + self.middles[arc] - end);
            const f = foot(piece_.at(@as(f64, if (ahead) 1 else 0) + (s - end) * rate));
            return .{ .point = f[0], .tangent = f[1].scale(rate), .curve = f[2].scale(rate * rate) };
        }
        const local = s - self.starts[k];
        const list = self.parts[k];
        const j = @min(list.len - 1, std.sort.partitionPoint(Part, list, local, endsBefore));
        const low: Part = if (j == 0) .{ .u = 0, .s = 0 } else list[j - 1];
        const high = list[j];
        // Newton's method on the part's parameter, from the length's share of the part, kept within the part.
        var u = low.u + (high.u - low.u) * std.math.clamp((local - low.s) / (high.s - low.s), 0, 1);
        var bracket = [2]f64{ low.u, high.u };
        for (0..64) |_| {
            const miss = measure.length(piece_, low.u, u) - (local - low.s);
            if (miss > 0) bracket[1] = u else bracket[0] = u;
            const next = u - miss / piece_.speed(u)[0];
            const kept = if (next > bracket[0] and next < bracket[1]) next else (bracket[0] + bracket[1]) / 2;
            if (kept == u) break;
            u = kept;
        }
        const f = foot(piece_.at(u));
        const speed = f[1].norm();
        const tangent = f[1].scale(1 / speed);
        return .{ .point = f[0], .tangent = tangent, .curve = f[2].sub(tangent.scale(tangent.dot(f[2]))).scale(1 / (speed * speed)) };
    }
};

/// What a guide's places do not allow, by a place's position in the guide.
pub const Fault = union(enum) {
    /// The place is at the point of the one before it: a polyline's leg, or a Bezier piece's end, has no length.
    together: usize,
    /// The corner at the place needs more of a leg than the leg has: the length its arc takes from each leg, and
    /// the place at the leg's other end, the leg's length.
    corner: struct { place: usize, takes: f64, other: usize, leg: f64 },
    /// The path from the place passes so near the geocentre that its ground length does not settle.
    unsettled: usize,
};

pub const Built = union(enum) { shape: Shape, fault: Fault };

/// How near a guide drawn on a map keeps to its path, in metres.
const outline_tolerance_m = 0.1;

pub fn build(arena: std.mem.Allocator, places: []const model.Place, g: model.Guide) std.mem.Allocator.Error!Built {
    const points = try arena.alloc(Ecef, g.places.len);
    for (points, g.places) |*p, index| p.* = places[index].ecef;
    var pieces: std.ArrayList(Piece) = .empty;
    const at = try arena.alloc(?usize, g.places.len);
    @memset(at, null);
    switch (g.shape) {
        .bezier => {
            for (0..(points.len - 1) / 3) |m| {
                const p = points[3 * m ..][0..4].*;
                if (std.meta.eql(p[0], p[1])) return .{ .fault = .{ .together = 3 * m + 1 } };
                if (std.meta.eql(p[2], p[3])) return .{ .fault = .{ .together = 3 * m + 3 } };
                at[3 * m] = pieces.items.len;
                try pieces.append(arena, .{ .cubic = p });
            }
            at[points.len - 1] = pieces.items.len;
        },
        .polyline => |radius| {
            for (points[1..], 1..) |p, i| if (std.meta.eql(p, points[i - 1])) return .{ .fault = .{ .together = i } };
            // Each corner's arc: how much of each leg it takes, where it begins and ends, and its turn.
            const reach = try arena.alloc(f64, points.len);
            const turn = try arena.alloc(f64, points.len);
            @memset(reach, 0);
            @memset(turn, 0);
            for (1..points.len - 1) |k| {
                const in = points[k].sub(points[k - 1]).unit();
                const out = points[k + 1].sub(points[k]).unit();
                turn[k] = std.math.acos(std.math.clamp(in.dot(out), -1, 1));
                reach[k] = radius * @tan(turn[k] / 2);
            }
            for (0..points.len - 1) |k| {
                const leg = points[k + 1].sub(points[k]).norm();
                if (!(reach[k] + reach[k + 1] <= leg)) {
                    const place = if (reach[k + 1] >= reach[k]) k + 1 else k;
                    return .{ .fault = .{ .corner = .{ .place = place, .takes = reach[place], .other = if (place == k) k + 1 else k, .leg = leg } } };
                }
            }
            at[0] = 0;
            var from = points[0];
            for (1..points.len) |k| {
                const in = points[k].sub(points[k - 1]).unit();
                const to = points[k].sub(in.scale(reach[k]));
                if (!std.meta.eql(to, from)) try pieces.append(arena, .{ .line = .{ .from = from, .to = to } });
                if (k + 1 == points.len or turn[k] == 0) {
                    at[k] = pieces.items.len;
                    from = to;
                    continue;
                }
                const out = points[k + 1].sub(points[k]).unit();
                const inward = out.sub(in).unit();
                const centre = points[k].add(inward.scale(radius / @cos(turn[k] / 2)));
                at[k] = pieces.items.len;
                // From the centre to where the arc begins, by the corner's angle: a radius below the points'
                // rounding leaves their difference no direction.
                const start = in.scale(@tan(turn[k] / 2)).add(inward.scale(1 / @cos(turn[k] / 2))).scale(-1);
                try pieces.append(arena, .{ .arc = .{ .centre = centre, .out = start, .along = in, .radius = radius, .angle = turn[k] } });
                from = points[k].add(out.scale(reach[k]));
            }
        },
    }
    const starts = try arena.alloc(f64, pieces.items.len + 1);
    const lists = try arena.alloc([]const Part, pieces.items.len);
    const middles = try arena.alloc(f64, pieces.items.len);
    starts[0] = 0;
    for (pieces.items, lists, middles, 0..) |p, *list, *middle, k| {
        // In halves at least, so that an arc's middle, where its corner's place is, ends a part.
        var ends: std.ArrayList(Part) = .empty;
        middle.* = (try split(arena, &ends, p, 0, 0.5, measure.length(p, 0, 0.5), 0, 0)) orelse return unsettled(at, k);
        starts[k + 1] = starts[k] + ((try split(arena, &ends, p, 0.5, 1, measure.length(p, 0.5, 1), middle.*, 0)) orelse return unsettled(at, k));
        list.* = ends.items;
    }
    const lengths_at = try arena.alloc(f64, g.places.len);
    for (lengths_at, at) |*s, piece_| {
        s.* = 0;
        const k = piece_ orelse continue;
        // A corner's place at its arc's middle; a place that ends the path at its end.
        s.* = if (k < pieces.items.len and pieces.items[k] == .arc) starts[k] + middles[k] else starts[k];
    }
    return .{ .shape = .{ .pieces = pieces.items, .starts = starts, .parts = lists, .middles = middles, .places = lengths_at } };
}

/// Points along a guide's path for a caller to draw, the path's first point first: each piece in steps of its
/// parameter, each halved until the path's points at its middle and its quarters lie within `outline_tolerance_m` of
/// those of the step drawn straight in latitude and longitude, as a map draws it (a short leg in one step), and in at
/// most `most_steps`.
pub fn outline(arena: std.mem.Allocator, shape: Shape, most_steps: usize) std.mem.Allocator.Error![]const Ecef {
    var out: std.ArrayList(Ecef) = .empty;
    try out.append(arena, shape.pieces[0].at(0)[0]);
    for (shape.pieces) |p| try trace(arena, &out, p, 0, 1, std.math.log2_int(usize, most_steps));
    return out.items;
}

fn before(s: f64, start: f64) bool {
    return start <= s;
}

fn endsBefore(s: f64, part: Part) bool {
    return part.s <= s;
}

/// Appends a piece's parts from low to high, `whole` the length from low to high and s0 the ground length to low
/// from the piece's start, a part halved until its length agrees with its halves'; returns the length to high, or
/// null where a part does not settle.
fn split(arena: std.mem.Allocator, ends: *std.ArrayList(Part), p: Piece, low: f64, high: f64, whole: f64, s0: f64, depth: usize) std.mem.Allocator.Error!?f64 {
    const mid = (low + high) / 2;
    const left = measure.length(p, low, mid);
    const right = measure.length(p, mid, high);
    if (measure.settles(whole, left, right, settled_m)) {
        try ends.append(arena, .{ .u = high, .s = s0 + whole });
        return s0 + whole;
    }
    if (depth == most_halvings or ends.items.len >= most_parts) return null;
    return split(arena, ends, p, mid, high, right, (try split(arena, ends, p, low, mid, left, s0, depth + 1)) orelse return null, depth + 1);
}

/// The foot on the ellipsoid of a point of the path, with its rates by the path's parameter.
fn foot(p: [3]Ecef) [3]Ecef {
    const local: frame.Frame = .at(frame.positionJet(p[0], p[1], p[2]));
    var out: [3][3]f64 = undefined;
    for (0..3) |axis| {
        const position = p[0].toArray()[axis];
        const f = (frame.Jet{ .value = position, .first = p[1].toArray()[axis], .second = p[2].toArray()[axis] }).sub(local.height.mul(local.up[axis]));
        out[0][axis] = f.value;
        out[1][axis] = f.first;
        out[2][axis] = f.second;
    }
    return .{ .fromArray(out[0]), .fromArray(out[1]), .fromArray(out[2]) };
}

/// Piece k's fault, by the place it begins at or after.
fn unsettled(at: []const ?usize, k: usize) Built {
    var place: usize = 0;
    for (at, 0..) |piece_, index| {
        if (piece_) |first| if (first <= k) {
            place = index;
        };
    }
    return .{ .fault = .{ .unsettled = place } };
}

/// A step of a piece from low to high, halved at most `halvings` times while it is not drawn within the tolerance.
fn trace(arena: std.mem.Allocator, out: *std.ArrayList(Ecef), p: Piece, low: f64, high: f64, halvings: usize) std.mem.Allocator.Error!void {
    const mid = (low + high) / 2;
    if (halvings > 0 and !drawn(p, low, high)) {
        try trace(arena, out, p, low, mid, halvings - 1);
        return trace(arena, out, p, mid, high, halvings - 1);
    }
    try out.append(arena, p.at(high)[0]);
}

/// Whether a step drawn straight in latitude and longitude passes within the tolerance of the path at its middle and
/// its quarters (the middle alone lies on the line of an S-shaped piece): the points on the ground, the step's
/// longitudes the nearer way round the meridian.
fn drawn(p: Piece, low: f64, high: f64) bool {
    const a = coordinates.ecefToLla(p.at(low)[0]);
    const b = coordinates.ecefToLla(p.at(high)[0]);
    const across = b.lon_rad - a.lon_rad;
    const east = across - angles.two_pi * @round(across / angles.two_pi);
    for ([_]f64{ 0.25, 0.5, 0.75 }) |f| {
        const on = coordinates.ecefToLla(p.at(low + (high - low) * f)[0]);
        const line = coordinates.llaToEcef(.{ .lat_rad = a.lat_rad + (b.lat_rad - a.lat_rad) * f, .lon_rad = a.lon_rad + east * f, .height_m = 0 });
        if (!(line.sub(coordinates.llaToEcef(.{ .lat_rad = on.lat_rad, .lon_rad = on.lon_rad, .height_m = 0 })).norm() <= outline_tolerance_m)) return false;
    }
    return true;
}
