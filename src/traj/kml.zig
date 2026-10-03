const std = @import("std");
const core = @import("shared").core;
const coord = core.coord;
const kml = @import("shared").trajectory.kml;
const Trajectory = @import("shared").trajectory.Trajectory;

pub fn write(w: *std.Io.Writer, traj: Trajectory) std.Io.Writer.Error!void {
    const name = if (traj.name.len > 0) traj.name else "Pharos trajectory";
    try kml.head(w, name, name);
    for (traj.knots, 0..) |k, i| {
        if (i > 0 and traj.knots[i - 1].t == k.t) continue;
        try kml.coordinate(w, coord.ecefToLla(k.pos));
    }
    try kml.foot(w);
}
