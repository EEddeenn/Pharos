const constants = @import("constants.zig");
const coord = @import("coord.zig");
const GpsTime = @import("time.zig").GpsTime;

const newton_iterations = 3;
const Scalar = Solver(f64, GpsTime);

pub const Sample = Scalar.Sample;
pub const Result = Scalar.Result;
pub const solve = Scalar.solve;

pub fn Solver(comptime Number: type, comptime Time: type) type {
    return struct {
        const Self = @This();
        const Point = coord.Cartesian(Number);
        const c: Number = if (Number == f64) constants.light_speed else @splat(constants.light_speed);
        const one: Number = if (Number == f64) 1.0 else @splat(1.0);

        pub const Sample = struct { pos: Point, vel: Point };

        pub const Result = struct {
            t_tx: Time,
            sat_vel: Point,
            range_m: Number,
            los: Point,
        };

        pub fn solve(source: anytype, rx_pos: Point, t_rx: Time, omega_e: Number, first: Self.Sample) Self.Result {
            var tau = first.pos.sub(rx_pos).norm() / c;
            var res: Self.Result = undefined;
            for (0..newton_iterations) |_| {
                res = evaluate(source, rx_pos, t_rx, tau, omega_e);
                const drho_dtau = -res.los.dot(res.sat_vel);
                tau += (res.range_m - c * tau) / (c - drho_dtau);
            }
            return evaluate(source, rx_pos, t_rx, tau, omega_e);
        }

        fn evaluate(source: anytype, rx_pos: Point, t_rx: Time, tau: Number, omega_e: Number) Self.Result {
            const t_tx = t_rx.minusSeconds(tau);
            const s = source.stateAt(t_tx);
            const theta = omega_e * tau;
            const pos = Point.rotateZ(s.pos, theta);
            const vel = Point.rotateZ(s.vel, theta);
            const d = pos.sub(rx_pos);
            const range = d.norm();
            return .{ .t_tx = t_tx, .sat_vel = vel, .range_m = range, .los = d.scale(one / range) };
        }
    };
}
