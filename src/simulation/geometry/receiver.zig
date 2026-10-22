const coordinates = @import("domain/earth/coordinates");

const Trajectory = @import("domain/trajectory/trajectory").Trajectory;

pub const State = struct { pos: coordinates.Ecef, vel: coordinates.Ecef };

pub const Frame = struct {
    pos: coordinates.Ecef,
    vel: coordinates.Ecef,
    lla: coordinates.Lla,
    enu: coordinates.EnuFrame,
    radius_m: f64,

    pub fn of(state: State) Frame {
        const lla = coordinates.ecefToLla(state.pos);
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
