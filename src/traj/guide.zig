//! A guide's path, in ECEF: a polyline's legs, chords from place to place, each corner rounded by an arc of the
//! guide's radius in the plane of the corner's two legs and tangent to both; or a Bezier's cubic pieces as they are.
//! Its ground track is the path's foot on the ellipsoid, by its length s over the ground: eight-point
//! Gauss-Legendre over each piece's parts, a part halved until its length agrees with its halves', and, for the
//! parameter of a length, Newton's method kept within its part.
const std = @import("std");
const shared = @import("shared");
const Ecef = shared.core.coord.Ecef;
const model = @import("plan.zig").model;
const frame = @import("frame.zig");
const track = @import("track.zig");

/// A part's length is settled when its halves' agree with it to a nanometre, or to its own rounding.
const settled_m = 1e-9;
const rounding = 4 * std.math.floatEps(f64);
/// A piece takes this many parts at most, each halved this many times at most: the hardest a caller draws (a
/// cusp, a tip of centimetres) takes some 30 parts; one that takes more passes so near the geocentre that its foot
/// is no longer one point of the ellipsoid.
const most_parts = 1024;
const most_halvings = 40;
const nodes = [8]f64{ -0.9602898564975363, -0.7966664774136267, -0.5255324099163290, -0.1834346424956498, 0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363 };
const weights = [8]f64{ 0.1012285362903763, 0.2223810344533745, 0.3137066458778873, 0.3626837833783620, 0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763 };

pub const Error = error{OutOfMemory};

/// A piece of the path by its parameter u from 0 to 1.
pub const Piece = union(enum) {
    line: struct { from: Ecef, to: Ecef },
    /// An arc about `centre` from `centre + radius out` turning towards `-out`, its first direction `along`.
    arc: struct { centre: Ecef, out: Ecef, along: Ecef, radius: f64, angle: f64 },
    cubic: [4]Ecef,

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
    /// The ground length where the path passes each place of the guide, by the place's position in it; a Bezier's
    /// control places, which it does not pass, are 0.
    places: []const f64,

    /// The piece that a length lies on: the last that begins at or before it.
    pub fn piece(self: *const Shape, s: f64) usize {
        return @max(1, std.sort.partitionPoint(f64, self.starts[0..self.pieces.len], s, before)) - 1;
    }

    /// The foot at ground length s on piece k, with its first and second rates by that length.
    pub fn ground(self: *const Shape, k: usize, s: f64) track.Point {
        const local = s - self.starts[k];
        const list = self.parts[k];
        const j = @min(list.len - 1, std.sort.partitionPoint(Part, list, local, endsBefore));
        const low: Part = if (j == 0) .{ .u = 0, .s = 0 } else list[j - 1];
        const high = list[j];
        const piece_ = self.pieces[k];
        // Newton's method on the part's parameter, from the length's share of the part, kept within the part.
        var u = low.u + (high.u - low.u) * std.math.clamp((local - low.s) / (high.s - low.s), 0, 1);
        var bracket = [2]f64{ low.u, high.u };
        for (0..64) |_| {
            const miss = length(piece_, low.u, u) - (local - low.s);
            if (miss > 0) bracket[1] = u else bracket[0] = u;
            const next = u - miss / footSpeed(piece_.at(u));
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

fn before(s: f64, start: f64) bool {
    return start <= s;
}

fn endsBefore(s: f64, part: Part) bool {
    return part.s <= s;
}

/// Appends a piece's parts from low to high, s0 the ground length to low from the piece's start, a part halved
/// until its length agrees with its halves'; returns the length to high, or null where a part does not settle.
fn split(arena: std.mem.Allocator, ends: *std.ArrayList(Part), p: Piece, low: f64, high: f64, s0: f64, depth: usize) Error!?f64 {
    const whole = length(p, low, high);
    const mid = (low + high) / 2;
    if (@abs(whole - length(p, low, mid) - length(p, mid, high)) <= @max(settled_m, rounding * whole)) {
        try ends.append(arena, .{ .u = high, .s = s0 + whole });
        return s0 + whole;
    }
    if (depth == most_halvings or ends.items.len >= most_parts) return null;
    return split(arena, ends, p, mid, high, (try split(arena, ends, p, low, mid, s0, depth + 1)) orelse return null, depth + 1);
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

/// The ground length of a piece between two of its parameters, by eight-point Gauss-Legendre.
fn length(p: Piece, low: f64, high: f64) f64 {
    var sum: f64 = 0;
    for (nodes, weights) |x, w| sum += w * footSpeed(p.at(low + (x + 1) / 2 * (high - low)));
    return sum * (high - low) / 2;
}

/// The rate of the foot's ground length by the path's parameter: over the ellipsoid, whose principal directions are
/// north and east (curvatures 1/M and 1/N), the foot moves by the path's tangent part over 1 + h/M north and
/// 1 + h/N east, at the height h.
fn footSpeed(p: [3]Ecef) f64 {
    const lla = shared.core.coord.ecefToLla(p[0]);
    const sine = @sin(lla.lat_rad);
    const cosine = @cos(lla.lat_rad);
    const e2 = shared.core.constants.wgs_e1_sqr;
    const w = 1 - e2 * sine * sine;
    const n = shared.core.constants.wgs_axis_a / @sqrt(w);
    const m = n * (1 - e2) / w;
    const east: Ecef = .{ .x = -@sin(lla.lon_rad), .y = @cos(lla.lon_rad), .z = 0 };
    const north: Ecef = .{ .x = -sine * @cos(lla.lon_rad), .y = -sine * @sin(lla.lon_rad), .z = cosine };
    return std.math.hypot(p[1].dot(north) / (1 + lla.height_m / m), p[1].dot(east) / (1 + lla.height_m / n));
}

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

pub fn build(arena: std.mem.Allocator, places: []const model.Place, g: model.Guide) Error!Built {
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
        middle.* = (try split(arena, &ends, p, 0, 0.5, 0, 0)) orelse return unsettled(at, k);
        starts[k + 1] = starts[k] + ((try split(arena, &ends, p, 0.5, 1, middle.*, 0)) orelse return unsettled(at, k));
        list.* = ends.items;
    }
    const lengths_at = try arena.alloc(f64, g.places.len);
    for (lengths_at, at) |*s, piece_| {
        s.* = 0;
        const k = piece_ orelse continue;
        // A corner's place at its arc's middle; a place that ends the path at its end.
        s.* = if (k < pieces.items.len and pieces.items[k] == .arc) starts[k] + middles[k] else starts[k];
    }
    return .{ .shape = .{ .pieces = pieces.items, .starts = starts, .parts = lists, .places = lengths_at } };
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

/// Points along a guide's path for a caller to draw: each piece cut into `subdivisions` equal steps of its parameter,
/// the path's first point first.
pub fn outline(arena: std.mem.Allocator, shape: Shape, subdivisions: usize) Error![]const Ecef {
    const count = std.math.add(usize, std.math.mul(usize, shape.pieces.len, subdivisions) catch return error.OutOfMemory, 1) catch return error.OutOfMemory;
    const out = try arena.alloc(Ecef, count);
    out[0] = shape.pieces[0].at(0)[0];
    for (shape.pieces, 0..) |p, k| {
        for (1..subdivisions + 1) |i| out[k * subdivisions + i] = p.at(@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(subdivisions)))[0];
    }
    return out;
}
