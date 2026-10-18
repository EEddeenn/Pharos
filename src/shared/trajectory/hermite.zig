pub fn Float(comptime Number: type) type {
    return struct {
        pub fn constant(value: f64) Number {
            return if (Number == f64) value else @splat(value);
        }

        pub fn add(a: Number, b: Number) Number {
            return a + b;
        }

        pub fn sub(a: Number, b: Number) Number {
            return a - b;
        }

        pub fn mul(a: Number, b: Number) Number {
            return a * b;
        }

        pub fn div(a: Number, b: Number) Number {
            return a / b;
        }

        pub fn scale(a: Number, factor: f64) Number {
            return a * constant(factor);
        }
    };
}

pub const Scalar = Interpolation(f64, Float(f64));

pub fn Interpolation(comptime Number: type, comptime Arithmetic: type) type {
    return struct {
        const A = Arithmetic;

        pub const Quintic = [6]Number;

        pub const CubicBasis = struct {
            h: Number,
            s: Number,
            s2: Number,
            h00: Number,
            h10: Number,
            h01: Number,
            h11: Number,

            pub fn velocity(self: CubicBasis) [4]Number {
                return .{
                    A.div(A.sub(A.scale(self.s2, 6), A.scale(self.s, 6)), self.h),
                    A.add(A.sub(A.scale(self.s2, 3), A.scale(self.s, 4)), A.constant(1)),
                    A.div(A.add(A.scale(self.s2, -6), A.scale(self.s, 6)), self.h),
                    A.sub(A.scale(self.s2, 3), A.scale(self.s, 2)),
                };
            }
        };

        pub fn cubicBasis(h: Number, s: Number) CubicBasis {
            const s2 = A.mul(s, s);
            const s3 = A.mul(s2, s);
            return .{
                .h = h,
                .s = s,
                .s2 = s2,
                .h00 = A.add(A.sub(A.scale(s3, 2), A.scale(s2, 3)), A.constant(1)),
                .h10 = A.add(A.sub(s3, A.scale(s2, 2)), s),
                .h01 = A.add(A.scale(s3, -2), A.scale(s2, 3)),
                .h11 = A.sub(s3, s2),
            };
        }

        pub const Motion = struct {
            position: Number,
            velocity: Number,
            acceleration: Number,
            jerk: Number,
        };

        pub fn quintic(p0: Number, v0: Number, a0: Number, p1: Number, v1: Number, a1: Number, h: Number) Quintic {
            const h2 = A.mul(h, h);
            const delta = A.sub(p1, p0);
            const left_v = A.mul(v0, h);
            const right_v = A.mul(v1, h);
            const left_a = A.mul(a0, h2);
            const right_a = A.mul(a1, h2);
            return .{
                p0,
                left_v,
                A.scale(left_a, 0.5),
                A.add(A.sub(A.sub(A.sub(A.scale(delta, 10), A.scale(left_v, 6)), A.scale(right_v, 4)), A.scale(left_a, 1.5)), A.scale(right_a, 0.5)),
                A.sub(A.add(A.add(A.add(A.scale(delta, -15), A.scale(left_v, 8)), A.scale(right_v, 7)), A.scale(left_a, 1.5)), right_a),
                A.add(A.sub(A.sub(A.sub(A.scale(delta, 6), A.scale(left_v, 3)), A.scale(right_v, 3)), A.scale(left_a, 0.5)), A.scale(right_a, 0.5)),
            };
        }

        pub fn evaluate(comptime order: usize, coefficients: anytype, u: Number) Number {
            const count = coefficients.len;
            if (order >= count) return A.constant(0);
            var result = A.scale(coefficients[count - 1], factor(count - 1, order));
            inline for (0..count - order - 1) |i| {
                const index = count - i - 2;
                result = A.add(A.mul(result, u), A.scale(coefficients[index], factor(index, order)));
            }
            return result;
        }

        pub fn motion(coefficients: Quintic, h: Number, u: Number) Motion {
            const h2 = A.mul(h, h);
            return .{
                .position = evaluate(0, coefficients, u),
                .velocity = A.div(evaluate(1, coefficients, u), h),
                .acceleration = A.div(evaluate(2, coefficients, u), h2),
                .jerk = A.div(evaluate(3, coefficients, u), A.mul(h2, h)),
            };
        }

        fn factor(comptime degree: usize, comptime order: usize) f64 {
            comptime var product: usize = 1;
            inline for (0..order) |i| product *= degree - i;
            return @floatFromInt(product);
        }
    };
}
