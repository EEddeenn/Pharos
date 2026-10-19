const std = @import("std");
const shared_trajectory = @import("shared").trajectory;
const Trajectory = shared_trajectory.Trajectory;
const check = @import("check.zig");

pub const Stats = struct {
    knots: usize,
    duration_s: f64,
    max_speed_mps: f64 = 0,
    max_acceleration_mps2: f64 = 0,
    max_jerk_mps3: f64 = 0,
    min_altitude_m: f64 = 0,
    max_altitude_m: f64 = 0,
    velocity_steps: usize = 0,
    largest_velocity_step_mps: f64 = 0,
    largest_velocity_step_s: ?f64 = null,
    acceleration_steps: usize = 0,
    largest_acceleration_step_mps2: f64 = 0,
    largest_acceleration_step_s: ?f64 = null,
};

/// The path's true extremes, read as its limits read it, and the steps its doubled knots make.
pub fn of(gpa: std.mem.Allocator, traj: Trajectory) check.Error!Stats {
    const extremes = try check.extremes(gpa, traj.knots);
    var st: Stats = .{
        .knots = traj.knots.len,
        .duration_s = traj.duration(),
        .max_speed_mps = extremes.speed_mps,
        .max_acceleration_mps2 = extremes.acceleration_mps2,
        .max_jerk_mps3 = extremes.jerk_mps3,
        .min_altitude_m = extremes.min_altitude_m,
        .max_altitude_m = extremes.max_altitude_m,
    };
    for (traj.knots[1..], traj.knots[0 .. traj.knots.len - 1]) |k, prev| {
        if (prev.t != k.t) continue;
        if (!std.meta.eql(prev.vel, k.vel)) {
            st.velocity_steps += 1;
            const size = k.vel.sub(prev.vel).norm();
            if (st.largest_velocity_step_s == null or size > st.largest_velocity_step_mps) {
                st.largest_velocity_step_mps = size;
                st.largest_velocity_step_s = k.t;
            }
        } else if (!std.meta.eql(prev.acc, k.acc)) {
            st.acceleration_steps += 1;
            const size = k.acc.sub(prev.acc).norm();
            if (st.largest_acceleration_step_s == null or size > st.largest_acceleration_step_mps2) {
                st.largest_acceleration_step_mps2 = size;
                st.largest_acceleration_step_s = k.t;
            }
        }
    }
    return st;
}
