const std = @import("std");
const core = @import("shared").core;
const coord = core.coord;
const shared_trajectory = @import("shared").trajectory;
const Trajectory = shared_trajectory.Trajectory;

pub const Stats = struct {
    knots: usize,
    duration_s: f64,
    max_speed_mps: f64 = 0,
    max_acceleration_mps2: f64 = 0,
    max_jerk_mps3: f64 = 0,
    min_altitude_m: f64 = std.math.inf(f64),
    max_altitude_m: f64 = -std.math.inf(f64),
    velocity_steps: usize = 0,
    first_velocity_step_s: ?f64 = null,
    acceleration_steps: usize = 0,
    largest_acceleration_step_mps2: f64 = 0,
    largest_acceleration_step_s: ?f64 = null,
};

const points_per_interval = 11;

pub fn of(traj: Trajectory) Stats {
    var st: Stats = .{ .knots = traj.knots.len, .duration_s = traj.duration() };
    for (traj.knots, 0..) |k, i| {
        observe(&st, .{ .pos = k.pos, .vel = k.vel, .acc = k.acc, .jerk = .{ .x = 0, .y = 0, .z = 0 } });
        if (i == 0) continue;
        const prev = traj.knots[i - 1];
        if (prev.t == k.t) {
            if (!std.meta.eql(prev.vel, k.vel)) {
                st.velocity_steps += 1;
                if (st.first_velocity_step_s == null) st.first_velocity_step_s = k.t;
            } else if (!std.meta.eql(prev.acc, k.acc)) {
                st.acceleration_steps += 1;
                const size = k.acc.sub(prev.acc).norm();
                if (st.largest_acceleration_step_s == null or size > st.largest_acceleration_step_mps2) {
                    st.largest_acceleration_step_mps2 = size;
                    st.largest_acceleration_step_s = k.t;
                }
            }
            continue;
        }
        for (0..points_per_interval) |p| {
            const t = prev.t + (k.t - prev.t) * @as(f64, @floatFromInt(p)) / (points_per_interval - 1);
            observe(&st, shared_trajectory.between(prev, k, t));
        }
    }
    return st;
}

fn observe(st: *Stats, s: shared_trajectory.State) void {
    st.max_speed_mps = @max(st.max_speed_mps, s.vel.norm());
    st.max_acceleration_mps2 = @max(st.max_acceleration_mps2, s.acc.norm());
    st.max_jerk_mps3 = @max(st.max_jerk_mps3, s.jerk.norm());
    const alt = core.geoid.altitude(coord.ecefToLla(s.pos));
    st.min_altitude_m = @min(st.min_altitude_m, alt);
    st.max_altitude_m = @max(st.max_altitude_m, alt);
}
