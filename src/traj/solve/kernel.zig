const std = @import("std");
const shared = @import("shared");
const domain = @import("kernel/domain.zig");

pub const autodiff = @import("kernel/autodiff.zig");
pub const Dual = autodiff.Dual;
pub const Requirements = domain.Requirements;
pub const Scalar = Evaluation(f64);
pub const Differential = Evaluation(Dual);

fn Evaluation(comptime N: type) type {
    return struct {
        pub const Number = N;
        pub const Arithmetic = Operations(N);
        pub const Hermite = shared.trajectory.hermite.Interpolation(N, Arithmetic);
        const Physical = domain.Domain(N, Arithmetic, if (N == f64) Float else N);
        pub const Vector = Physical.Vector;
        pub const State = Physical.State;
        pub const Frame = Physical.Frame;
        pub const Point = Physical.Point;
        pub const scalar = Physical.scalar;
        pub const vector = Physical.vector;
        pub const dot = Physical.dot;
        pub const norm = Physical.norm;
        pub const normSquared = Physical.normSquared;
        pub const frame = Physical.frame;

        pub const Jet = struct {
            position: Vector,
            velocity: Vector,
            acceleration: Vector,
        };

        pub const Cell = struct {
            position: [3]Hermite.Quintic,
            duration: N,

            pub fn init(a: Jet, b: Jet, h: N) Cell {
                var coefficients: [3]Hermite.Quintic = undefined;
                for (0..3) |axis| coefficients[axis] = Hermite.quintic(a.position[axis], a.velocity[axis], a.acceleration[axis], b.position[axis], b.velocity[axis], b.acceleration[axis], h);
                return .{ .position = coefficients, .duration = h };
            }

            pub fn at(self: Cell, u: N) State {
                var result: State = undefined;
                for (0..3) |axis| {
                    const motion = Hermite.motion(self.position[axis], self.duration, u);
                    result.position[axis] = motion.position;
                    result.velocity[axis] = motion.velocity;
                    result.acceleration[axis] = motion.acceleration;
                    result.jerk[axis] = motion.jerk;
                }
                return result;
            }
        };

        pub fn at(a: Jet, b: Jet, h: N, u: N) State {
            return Cell.init(a, b, h).at(u);
        }
    };
}

fn Operations(comptime N: type) type {
    return struct {
        pub fn constant(number: f64) N {
            return if (N == f64) number else N.constant(number);
        }

        pub fn value(number: N) f64 {
            return if (N == f64) number else number.value;
        }

        pub fn add(a: N, b: N) N {
            return if (N == f64) a + b else a.add(b);
        }

        pub fn sub(a: N, b: N) N {
            return if (N == f64) a - b else a.sub(b);
        }

        pub fn mul(a: N, b: N) N {
            return if (N == f64) a * b else a.mul(b);
        }

        pub fn div(a: N, b: N) N {
            return if (N == f64) a / b else a.div(b);
        }

        pub fn scale(a: N, factor: f64) N {
            return if (N == f64) a * factor else a.scale(factor);
        }

        pub fn neg(a: N) N {
            return if (N == f64) -a else a.neg();
        }

        pub fn sqrt(a: N) N {
            return if (N == f64) @sqrt(a) else a.sqrt();
        }

        pub fn atan2(y: N, x: N) N {
            return if (N == f64) std.math.atan2(y, x) else y.atan2(x);
        }

        pub fn pow(a: N, exponent: f64) N {
            return if (N == f64) std.math.pow(f64, a, exponent) else a.pow(exponent);
        }

        pub fn log(a: N) N {
            return if (N == f64) @log(a) else a.log();
        }

        pub fn isFinite(a: N) bool {
            return if (N == f64) std.math.isFinite(a) else a.isFinite();
        }
    };
}

const Float = struct {
    value: f64,

    pub fn constant(value: f64) Float {
        return .{ .value = value };
    }

    pub fn add(a: Float, b: Float) Float {
        return .constant(a.value + b.value);
    }

    pub fn sub(a: Float, b: Float) Float {
        return .constant(a.value - b.value);
    }

    pub fn mul(a: Float, b: Float) Float {
        return .constant(a.value * b.value);
    }

    pub fn div(a: Float, b: Float) Float {
        return .constant(a.value / b.value);
    }

    pub fn scale(a: Float, factor: f64) Float {
        return .constant(a.value * factor);
    }

    pub fn neg(a: Float) Float {
        return .constant(-a.value);
    }

    pub fn sqrt(a: Float) Float {
        return .constant(@sqrt(a.value));
    }

    pub fn sinCos(a: Float) struct { sine: Float, cosine: Float } {
        return .{ .sine = .constant(@sin(a.value)), .cosine = .constant(@cos(a.value)) };
    }

    pub fn atan2(y: Float, x: Float) Float {
        return .constant(std.math.atan2(y.value, x.value));
    }
};
