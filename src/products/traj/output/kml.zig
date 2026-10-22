const std = @import("std");
const coordinates = @import("domain/earth/coordinates");
const trajectory = @import("domain/trajectory/trajectory");
const kml = @import("domain/trajectory/formats/kml");

const Ecef = coordinates.Ecef;
const Knot = trajectory.Knot;
const Trajectory = trajectory.Trajectory;

/// How near the line keeps to the stored path, in metres: a viewer draws it straight through space from point to
/// point.
const tolerance_m = 0.1;
/// A piece is halved at most this many times: 4096 steps.
const most_halvings = 12;

/// The stored path as a line: each piece in steps of its time, each halved while the path passes farther than the
/// tolerance from the step drawn straight, at its quarters and its middle.
pub fn write(w: *std.Io.Writer, traj: Trajectory) std.Io.Writer.Error!void {
    const name = if (traj.name.len > 0) traj.name else "Pharos trajectory";
    try kml.head(w, name, name);
    try kml.coordinate(w, coordinates.ecefToLla(traj.knots[0].pos));
    // A line string takes two points: a path of no duration, one point, is that point twice.
    if (traj.duration() == 0) try kml.coordinate(w, coordinates.ecefToLla(traj.knots[0].pos));
    for (traj.knots[0 .. traj.knots.len - 1], traj.knots[1..]) |k0, k1| {
        if (k1.t > k0.t) try step(w, k0, k1, .{ k0.t, k1.t }, .{ k0.pos, k1.pos }, most_halvings);
    }
    try kml.foot(w);
}

/// A step of the piece from k0 to k1 between two times, at two points; its end written.
fn step(w: *std.Io.Writer, k0: Knot, k1: Knot, times: [2]f64, ends: [2]Ecef, halvings: usize) std.Io.Writer.Error!void {
    if (halvings > 0 and !straight(k0, k1, times, ends)) {
        const mid = (times[0] + times[1]) / 2;
        const point = trajectory.between(k0, k1, mid).pos;
        try step(w, k0, k1, .{ times[0], mid }, .{ ends[0], point }, halvings - 1);
        return step(w, k0, k1, .{ mid, times[1] }, .{ point, ends[1] }, halvings - 1);
    }
    try kml.coordinate(w, coordinates.ecefToLla(ends[1]));
}

/// Whether the path keeps within the tolerance of the line between a step's ends, at its quarters and its middle.
fn straight(k0: Knot, k1: Knot, times: [2]f64, ends: [2]Ecef) bool {
    const chord = ends[1].sub(ends[0]);
    const square = chord.dot(chord);
    for ([_]f64{ 0.25, 0.5, 0.75 }) |f| {
        const off = trajectory.between(k0, k1, times[0] + (times[1] - times[0]) * f).pos.sub(ends[0]);
        const across = if (square > 0) off.sub(chord.scale(std.math.clamp(off.dot(chord) / square, 0, 1))) else off;
        if (!(across.norm() <= tolerance_m)) return false;
    }
    return true;
}
