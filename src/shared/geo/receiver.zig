const core = @import("../core.zig");
const coord = core.coord;
const Trajectory = @import("../trajectory.zig").Trajectory;

pub const State = struct { pos: coord.Ecef, vel: coord.Ecef };

pub const Frame = struct {
    pos: coord.Ecef,
    vel: coord.Ecef,
    lla: coord.Lla,
    enu: coord.EnuFrame,
    radius_m: f64,

    pub fn of(state: State) Frame {
        const lla = coord.ecefToLla(state.pos);
        return .{ .pos = state.pos, .vel = state.vel, .lla = lla, .enu = .at(lla), .radius_m = state.pos.norm() };
    }
};

pub fn at(traj: *const Trajectory, t_s: f64) Frame {
    const state = traj.at(t_s);
    return .of(.{ .pos = state.pos, .vel = state.vel });
}

pub fn atMs(traj: *const Trajectory, ms: u64) Frame {
    return at(traj, @as(f64, @floatFromInt(ms)) / 1000.0);
}
