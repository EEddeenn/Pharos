const std = @import("std");
const core = @import("shared").core;
const model = @import("../../plan.zig").model;
const directed = @import("../../plan.zig").quantities.directed;
const constants = core.constants;

/// The horizontal speed, in m/s, at or under which the path is at rest and has no direction of travel: under it a
/// heading read off the motion is noise. A hard rule of rest admits much less, each component of the velocity
/// within the verifier's tolerance (up to 1.4e-5 m/s horizontally), so a path such a rule holds is at rest here.
pub const rest_speed: f64 = 1e-3;

pub const Requirements = struct {
    frame: ?u2,
    horizontal: ?u2,
    height: ?u2,
    heading: ?u2,
    forward: ?u2,

    pub fn init(quantities: []const model.Quantity) Requirements {
        var frame_need: ?u2 = null;
        var horizontal_need: ?u2 = null;
        var height_need: ?u2 = null;
        var heading_need: ?u2 = null;
        var forward_need: ?u2 = null;
        for (quantities) |requested| {
            switch (requested) {
                .altitude => require(&height_need, 0),
                .climb_rate => require(&height_need, 1),
                .vertical_acceleration => require(&height_need, 2),
                .horizontal_speed, .forward_speed => require(&horizontal_need, 0),
                .course => require(&heading_need, 0),
                .turn_rate => require(&heading_need, 1),
                .forward_acceleration => require(&forward_need, 1),
                .forward_jerk => require(&forward_need, 2),
                .lateral_acceleration => {
                    require(&horizontal_need, 1);
                    require(&heading_need, 0);
                },
                .turn_radius => {
                    require(&forward_need, 0);
                    require(&heading_need, 1);
                },
                else => {},
            }
        }
        if (forward_need) |order| {
            require(&horizontal_need, order);
            require(&heading_need, order);
        }
        if (heading_need) |order| require(&horizontal_need, order);
        if (horizontal_need) |order| require(&frame_need, order);
        if (height_need) |order| require(&frame_need, order);
        return .{ .frame = frame_need, .horizontal = horizontal_need, .height = height_need, .heading = heading_need, .forward = forward_need };
    }
};

fn require(current: *?u2, order: u2) void {
    current.* = @max(current.* orelse 0, order);
}

pub fn Domain(comptime N: type, comptime Ops: type, comptime D: type) type {
    return struct {
        pub const Number = N;
        pub const Arithmetic = Ops;
        pub const Vector = [3]N;

        pub const State = struct {
            position: Vector,
            velocity: Vector,
            acceleration: Vector,
            jerk: Vector,
        };

        pub const Frame = struct {
            east: Vector,
            north: Vector,
            up: Vector,
            height: N,
        };

        pub fn scalar(value: N) Vector {
            return .{ value, Ops.constant(0), Ops.constant(0) };
        }

        pub fn vector(value: [3]f64) Vector {
            return .{ Ops.constant(value[0]), Ops.constant(value[1]), Ops.constant(value[2]) };
        }

        pub fn dot(a: Vector, b: Vector) N {
            return Ops.add(Ops.add(Ops.mul(a[0], b[0]), Ops.mul(a[1], b[1])), Ops.mul(a[2], b[2]));
        }

        pub fn normSquared(v: Vector) N {
            return dot(v, v);
        }

        pub fn norm(v: Vector) N {
            const squared = normSquared(v);
            return if (Ops.value(squared) == 0 and Ops.isFinite(squared)) Ops.constant(0) else Ops.sqrt(squared);
        }

        pub fn frame(position: Vector) Frame {
            var p: [3]Motion(0) = undefined;
            for (&p, position) |*out, value| out.* = Motion(0).of(take(value));
            const local = movingFrame(0, p);
            return .{ .east = values(0, local.east), .north = values(0, local.north), .up = values(0, local.up), .height = give(local.height.value) };
        }

        pub const Point = struct {
            state: State,
            datum: model.Altitude,
            /// The horizontal velocity is taken in the frame of where the path is, the place there held: its
            /// derivatives are then those of the velocity alone, and it is linear in the path (the convex tier).
            hold_frame: bool = false,
            frame_order: ?u2 = null,
            frame_cache: MovingFrame(2) = undefined,
            height_order: ?u2 = null,
            height_cache: Motion(2) = undefined,
            horizontal_order: ?u2 = null,
            horizontal_cache: [2]Motion(2) = undefined,
            heading_order: ?u2 = null,
            heading_cache: Motion(2) = undefined,
            trigonometry_order: ?u2 = null,
            sine_cache: Motion(2) = undefined,
            cosine_cache: Motion(2) = undefined,
            forward_order: ?u2 = null,
            forward_cache: Motion(2) = undefined,

            pub fn init(state: State, datum: model.Altitude) Point {
                return .{ .state = state, .datum = datum };
            }

            pub fn prepareRequirements(self: *Point, requirements: Requirements) void {
                if (requirements.frame) |order| switch (order) {
                    0 => _ = self.local(0),
                    1 => _ = self.local(1),
                    2 => _ = self.local(2),
                    3 => unreachable,
                };
                if (requirements.horizontal) |order| switch (order) {
                    0 => _ = self.horizontal(0),
                    1 => _ = self.horizontal(1),
                    2 => _ = self.horizontal(2),
                    3 => unreachable,
                };
                if (requirements.height) |order| switch (order) {
                    0 => _ = self.height(0),
                    1 => _ = self.height(1),
                    2 => _ = self.height(2),
                    3 => unreachable,
                };
                if (requirements.heading) |order| switch (order) {
                    0 => _ = self.heading(0),
                    1 => _ = self.heading(1),
                    2 => _ = self.heading(2),
                    3 => unreachable,
                };
                if (requirements.forward) |order| switch (order) {
                    0 => _ = self.forward(0),
                    1 => _ = self.forward(1),
                    2 => _ = self.forward(2),
                    3 => unreachable,
                };
            }

            pub fn atRest(self: *Point) bool {
                const velocity = self.horizontalVelocity();
                return std.math.hypot(Ops.value(velocity[0]), Ops.value(velocity[1])) <= rest_speed;
            }

            pub fn horizontalVelocity(self: *Point) [2]N {
                const components = self.horizontal(0);
                return .{ give(components[0].value), give(components[1].value) };
            }

            /// A quantity that hangs on the direction of travel is NaN where the path is at rest.
            pub fn quantity(self: *Point, requested: model.Quantity) Vector {
                if (directed(requested) and self.atRest()) return scalar(Ops.constant(std.math.nan(f64)));
                return switch (requested) {
                    .position => self.state.position,
                    .velocity_ecef => self.state.velocity,
                    .acceleration_ecef => self.state.acceleration,
                    .speed3d => scalar(norm(self.state.velocity)),
                    .acceleration3d => scalar(norm(self.state.acceleration)),
                    .jerk3d => scalar(norm(self.state.jerk)),
                    .course => scalar(give(self.heading(0).value.scale(constants.rad2deg(1)))),
                    .turn_rate => scalar(give(self.heading(1).first.scale(constants.rad2deg(1)))),
                    .time, .duration => scalar(Ops.constant(std.math.nan(f64))),
                    .altitude => scalar(give(self.height(0).value)),
                    .climb_rate => scalar(give(self.height(1).first)),
                    .vertical_acceleration => scalar(give(self.height(2).second)),
                    .horizontal_speed, .forward_speed => blk: {
                        const components = self.horizontalVelocity();
                        break :blk scalar(norm(.{ components[0], components[1], Ops.constant(0) }));
                    },
                    .forward_acceleration => scalar(give(self.forward(1).first)),
                    .forward_jerk => scalar(give(self.forward(2).second)),
                    .lateral_acceleration => blk: {
                        const components = self.horizontal(1);
                        const trig = self.trigonometry(0);
                        break :blk scalar(give(components[0].first.mul(trig.cosine.value).sub(components[1].first.mul(trig.sine.value))));
                    },
                    .turn_radius => scalar(give(self.forward(0).value.div(self.heading(1).first))),
                };
            }

            fn local(self: *Point, comptime order: u2) MovingFrame(order) {
                if (self.frame_order == null or self.frame_order.? < order) {
                    var position: [3]Motion(order) = undefined;
                    for (0..3) |i| position[i] = .{
                        .value = take(self.state.position[i]),
                        .first = if (order >= 1) take(self.state.velocity[i]) else {},
                        .second = if (order >= 2) take(self.state.acceleration[i]) else {},
                    };
                    const computed = movingFrame(order, position);
                    inline for (.{ "east", "north", "up" }) |field| {
                        for (0..3) |i| @field(self.frame_cache, field)[i] = computedField(order, @field(computed, field)[i]);
                    }
                    self.frame_cache.height = computedField(order, computed.height);
                    self.frame_order = order;
                }
                var result: MovingFrame(order) = undefined;
                inline for (.{ "east", "north", "up" }) |field| {
                    for (0..3) |i| @field(result, field)[i] = select(order, @field(self.frame_cache, field)[i]);
                }
                result.height = select(order, self.frame_cache.height);
                return result;
            }

            /// The local frame with the place held: a number where `local` gives a function of the unknowns.
            fn held(self: *const Point, comptime order: u2) MovingFrame(order) {
                var position: [3]Motion(order) = undefined;
                for (0..3) |i| position[i] = .{
                    .value = D.constant(take(self.state.position[i]).value),
                    .first = if (order >= 1) take(self.state.velocity[i]) else {},
                    .second = if (order >= 2) take(self.state.acceleration[i]) else {},
                };
                return movingFrame(order, position);
            }

            fn horizontal(self: *Point, comptime order: u2) [2]Motion(order) {
                if (self.horizontal_order == null or self.horizontal_order.? < order) {
                    const local_frame = if (self.hold_frame) self.held(order) else self.local(order);
                    var velocity: [3]Motion(order) = undefined;
                    for (0..3) |i| velocity[i] = .{
                        .value = take(self.state.velocity[i]),
                        .first = if (order >= 1) take(self.state.acceleration[i]) else {},
                        .second = if (order >= 2) take(self.state.jerk[i]) else {},
                    };
                    self.horizontal_cache = .{
                        computedField(order, dotMotion(order, local_frame.east, velocity)),
                        computedField(order, dotMotion(order, local_frame.north, velocity)),
                    };
                    self.horizontal_order = order;
                }
                return .{ select(order, self.horizontal_cache[0]), select(order, self.horizontal_cache[1]) };
            }

            fn height(self: *Point, comptime order: u2) Motion(order) {
                if (self.height_order == null or self.height_order.? < order) {
                    const local_frame = self.local(order);
                    const computed = if (self.datum == .ellipsoid) local_frame.height else local_frame.height.sub(core.geoid.Evaluator(Motion(order), Motion(order).Arithmetic).height(local_frame.up));
                    self.height_cache = computedField(order, computed);
                    self.height_order = order;
                }
                return select(order, self.height_cache);
            }

            fn heading(self: *Point, comptime order: u2) Motion(order) {
                if (self.heading_order == null or self.heading_order.? < order) {
                    const components = self.horizontal(order);
                    self.heading_cache = computedField(order, components[0].atan2(components[1]));
                    self.heading_order = order;
                }
                return select(order, self.heading_cache);
            }

            fn trigonometry(self: *Point, comptime order: u2) struct { sine: Motion(order), cosine: Motion(order) } {
                if (self.trigonometry_order == null or self.trigonometry_order.? < order) {
                    const orientation = self.heading(order);
                    const trig = orientation.sinCos();
                    self.sine_cache = computedField(order, trig.sine);
                    self.cosine_cache = computedField(order, trig.cosine);
                    self.trigonometry_order = order;
                }
                return .{ .sine = select(order, self.sine_cache), .cosine = select(order, self.cosine_cache) };
            }

            fn forward(self: *Point, comptime order: u2) Motion(order) {
                if (self.forward_order == null or self.forward_order.? < order) {
                    const components = self.horizontal(order);
                    const trig = self.trigonometry(order);
                    self.forward_cache = computedField(order, components[0].mul(trig.sine).add(components[1].mul(trig.cosine)));
                    self.forward_order = order;
                }
                return select(order, self.forward_cache);
            }
        };

        fn take(value: N) D {
            return if (N == f64) .{ .value = value } else value;
        }

        fn give(value: D) N {
            return if (N == f64) value.value else value;
        }

        fn computedField(comptime order: u2, value: Motion(order)) Motion(2) {
            return .{ .value = value.value, .first = if (order >= 1) value.first else undefined, .second = if (order >= 2) value.second else undefined };
        }

        fn select(comptime order: u2, value: Motion(2)) Motion(order) {
            return .{ .value = value.value, .first = if (order >= 1) value.first else {}, .second = if (order >= 2) value.second else {} };
        }

        fn Motion(comptime order: u2) type {
            return struct {
                value: D,
                first: if (order >= 1) D else void,
                second: if (order >= 2) D else void,
                const M = @This();

                const Arithmetic = struct {
                    pub const constant = M.constant;
                    pub const failed = M.failed;
                    pub const add = M.add;
                    pub const sub = M.sub;
                    pub const mul = M.mul;
                    pub const scale = M.scale;
                    pub const sqrt = M.sqrt;
                    pub const atan2 = M.atan2;

                    pub fn value(number: M) f64 {
                        return number.value.value;
                    }
                };

                fn of(value: D) M {
                    return .{ .value = value, .first = if (order >= 1) D.constant(0) else {}, .second = if (order >= 2) D.constant(0) else {} };
                }

                fn constant(value: f64) M {
                    return of(D.constant(value));
                }
                fn failed() M {
                    const nan = D.constant(std.math.nan(f64));
                    return .{ .value = nan, .first = if (order >= 1) nan else {}, .second = if (order >= 2) nan else {} };
                }

                fn add(a: M, b: M) M {
                    return .{ .value = a.value.add(b.value), .first = if (order >= 1) a.first.add(b.first) else {}, .second = if (order >= 2) a.second.add(b.second) else {} };
                }

                fn sub(a: M, b: M) M {
                    return .{ .value = a.value.sub(b.value), .first = if (order >= 1) a.first.sub(b.first) else {}, .second = if (order >= 2) a.second.sub(b.second) else {} };
                }

                fn scale(a: M, k: f64) M {
                    return .{ .value = a.value.scale(k), .first = if (order >= 1) a.first.scale(k) else {}, .second = if (order >= 2) a.second.scale(k) else {} };
                }

                fn mul(a: M, b: M) M {
                    return .{
                        .value = a.value.mul(b.value),
                        .first = if (order >= 1) a.first.mul(b.value).add(a.value.mul(b.first)) else {},
                        .second = if (order >= 2) a.second.mul(b.value).add(a.first.mul(b.first).scale(2)).add(a.value.mul(b.second)) else {},
                    };
                }

                fn div(a: M, b: M) M {
                    const value = a.value.div(b.value);
                    const first = if (order >= 1) a.first.sub(value.mul(b.first)).div(b.value) else {};
                    return .{
                        .value = value,
                        .first = first,
                        .second = if (order >= 2) a.second.sub(first.mul(b.first).scale(2)).sub(value.mul(b.second)).div(b.value) else {},
                    };
                }

                fn sqrt(a: M) M {
                    const value = a.value.sqrt();
                    const first = if (order >= 1) a.first.div(value).scale(0.5) else {};
                    return .{ .value = value, .first = first, .second = if (order >= 2) a.second.scale(0.5).sub(first.mul(first)).div(value) else {} };
                }

                fn sinCos(a: M) struct { sine: M, cosine: M } {
                    const trig = a.value.sinCos();
                    const squared = if (order >= 2) a.first.mul(a.first) else {};
                    return .{
                        .sine = .{
                            .value = trig.sine,
                            .first = if (order >= 1) trig.cosine.mul(a.first) else {},
                            .second = if (order >= 2) trig.cosine.mul(a.second).sub(trig.sine.mul(squared)) else {},
                        },
                        .cosine = .{
                            .value = trig.cosine,
                            .first = if (order >= 1) trig.sine.mul(a.first).neg() else {},
                            .second = if (order >= 2) trig.sine.mul(a.second).neg().sub(trig.cosine.mul(squared)) else {},
                        },
                    };
                }

                fn atan2(y: M, x: M) M {
                    if (order == 0) return .of(y.value.atan2(x.value));
                    const scale_by = 1 / @max(@abs(x.value.value), @abs(y.value.value));
                    const xs = x.scale(scale_by);
                    const ys = y.scale(scale_by);
                    const squared = xs.value.mul(xs.value).add(ys.value.mul(ys.value));
                    const first = xs.value.mul(ys.first).sub(ys.value.mul(xs.first)).div(squared);
                    const radial = if (order >= 2) xs.value.mul(xs.first).add(ys.value.mul(ys.first)) else {};
                    return .{
                        .value = y.value.atan2(x.value),
                        .first = first,
                        .second = if (order >= 2) xs.value.mul(ys.second).sub(ys.value.mul(xs.second)).sub(radial.mul(first).scale(2)).div(squared) else {},
                    };
                }
            };
        }

        fn MovingFrame(comptime order: u2) type {
            return struct {
                east: [3]Motion(order),
                north: [3]Motion(order),
                up: [3]Motion(order),
                height: Motion(order),

                fn failed() @This() {
                    return .{ .east = @splat(Motion(order).failed()), .north = @splat(Motion(order).failed()), .up = @splat(Motion(order).failed()), .height = Motion(order).failed() };
                }
            };
        }

        fn values(comptime order: u2, v: [3]Motion(order)) Vector {
            return .{ give(v[0].value), give(v[1].value), give(v[2].value) };
        }

        fn dotMotion(comptime order: u2, a: [3]Motion(order), b: [3]Motion(order)) Motion(order) {
            return a[0].mul(b[0]).add(a[1].mul(b[1])).add(a[2].mul(b[2]));
        }

        fn unit(comptime order: u2, v: [3]Motion(order)) [3]Motion(order) {
            const magnitude = dotMotion(order, v, v).sqrt();
            return .{ v[0].div(magnitude), v[1].div(magnitude), v[2].div(magnitude) };
        }

        fn cross(comptime order: u2, a: [3]Motion(order), b: [3]Motion(order)) [3]Motion(order) {
            return .{
                a[1].mul(b[2]).sub(a[2].mul(b[1])),
                a[2].mul(b[0]).sub(a[0].mul(b[2])),
                a[0].mul(b[1]).sub(a[1].mul(b[0])),
            };
        }

        fn movingFrame(comptime order: u2, position: [3]Motion(order)) MovingFrame(order) {
            const Jet = Motion(order);
            const primal = core.coord.Ecef{ .x = position[0].value.value, .y = position[1].value.value, .z = position[2].value.value };
            for (primal.toArray()) |value| if (!std.math.isFinite(value)) return MovingFrame(order).failed();
            if (primal.norm() == 0 or !std.math.isFinite(primal.norm())) return MovingFrame(order).failed();

            const a = constants.wgs_axis_a;
            const beta2 = 1 - constants.wgs_e1_sqr;
            const initial = core.coord.ecefToLla(primal);
            const sine = @sin(initial.lat_rad);
            var multiplier = Jet.constant(initial.height_m / a * @sqrt(1 - constants.wgs_e1_sqr * sine * sine));
            var r: [3]Jet = undefined;
            for (&r, position) |*out, value| out.* = value.scale(1 / a);
            const horizontal = r[0].mul(r[0]).add(r[1].mul(r[1]));
            const vertical = r[2].mul(r[2]).scale(beta2);
            for (0..3) |_| {
                const equatorial = multiplier.add(Jet.constant(1));
                const polar = multiplier.add(Jet.constant(beta2));
                const equatorial2 = equatorial.mul(equatorial);
                const polar2 = polar.mul(polar);
                const residual = horizontal.div(equatorial2).add(vertical.div(polar2)).sub(Jet.constant(1));
                const slope = horizontal.div(equatorial2.mul(equatorial)).add(vertical.div(polar2.mul(polar))).scale(-2);
                multiplier = multiplier.sub(residual.div(slope));
            }
            const equatorial = multiplier.add(Jet.constant(1));
            const polar = multiplier.add(Jet.constant(beta2));
            const up = unit(order, .{ r[0].div(equatorial), r[1].div(equatorial), r[2].div(polar) });
            const support = up[0].mul(up[0]).add(up[1].mul(up[1])).add(up[2].mul(up[2]).scale(beta2)).sqrt();
            const height = dotMotion(order, r, up).sub(support).scale(a);
            const east = if (primal.x * primal.x + primal.y * primal.y <= 1e-12)
                unit(order, .{ up[0].mul(up[1]).scale(-1), Jet.constant(1).sub(up[1].mul(up[1])), up[2].mul(up[1]).scale(-1) })
            else
                unit(order, .{ up[1].scale(-1), up[0], Jet.constant(0) });
            return .{ .east = east, .north = cross(order, up, east), .up = up, .height = height };
        }
    };
}
