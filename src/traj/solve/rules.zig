const std = @import("std");
const shared = @import("shared");
const rest_speed = @import("kernel/domain.zig").rest_speed;
const plan_module = @import("../plan.zig");
const model = plan_module.model;
const quantities = plan_module.quantities;

pub const Comparison = enum { eq, min, max, target, objective };
pub const Mode = enum { optimization, verification };
pub const Operation = union(enum) {
    quantity: struct { rule: usize, comparison: Comparison, component: usize, split_norm: bool = false },
    /// Beside a hard course of a stated number at an event, which the optimiser holds as no velocity across it:
    /// the velocity there goes along that course, at least as fast as a direction of travel needs (`rest_speed`).
    ahead: usize,
    curve: struct { rule: usize, component: usize },
    region: struct { rule: usize, edge: usize },
    coverage: f64,
    maximum_duration,
    jump: Step,
    /// Under a rule of turning, at an event where the velocity may step: of the horizontal velocities of its two
    /// sides nothing of one across the other (`component` 0), and the two not opposed (1). The direction of travel
    /// then steps by no angle; the speed may step. `quantity` is the velocity, which is what the two rows read.
    corner: Step,
};

pub const Step = struct { event: usize, quantity: model.Quantity, component: usize, range: ?[2]f64 = null };

pub const Check = struct {
    scope: model.Scope,
    operation: Operation,
    equality: bool = false,
    weight: f64 = 1,
    square: bool = true,
    integral: bool = false,
    average_scope: ?model.Scope = null,

    pub fn ruleIndex(self: Check) ?usize {
        return switch (self.operation) {
            .quantity => |q| q.rule,
            .ahead => |rule| rule,
            .curve => |c| c.rule,
            .region => |r| r.rule,
            else => null,
        };
    }
};

pub const Curve = struct { kind: model.CurveKind, points: []const [3]f64 };
pub const Edge = struct { start: [2]f64, delta: [2]f64, inverse_length: f64 };
pub const Region = struct {
    origin: [3]f64,
    east: [3]f64,
    north: [3]f64,
    shape: union(enum) { circle: f64, polygon: []const Edge },
};

pub const Prepared = struct {
    plan: *const model.Plan,
    checks: []const Check,
    regions: []const Region,
    curves: []const Curve,

    pub fn isObjective(self: *const Prepared, check: Check) bool {
        return if (check.ruleIndex()) |index| self.plan.rules[index].kind() != .hard else false;
    }
};

pub fn prepare(arena: std.mem.Allocator, plan: *const model.Plan) std.mem.Allocator.Error!Prepared {
    const curves = try arena.alloc(Curve, plan.geometry.curves.len);
    for (curves, plan.geometry.curves) |*out, curve| {
        const points = try arena.alloc([3]f64, curve.points.len);
        for (points, curve.points) |*point, index| point.* = plan.geometry.points[index].ecef.toArray();
        out.* = .{ .kind = curve.kind, .points = points };
    }
    const regions = try arena.alloc(Region, plan.geometry.regions.len);
    for (regions, plan.geometry.regions) |*out, region| {
        const plane = switch (region.shape) {
            .circle => |circle| plan_module.geometry.Plane.at(plan.geometry.points[circle.center].ecef),
            .polygon => |points| plan_module.geometry.polygonPlane(plan.geometry.points, points),
        };
        out.* = .{ .origin = plane.origin.toArray(), .east = plane.frame.rows[0], .north = plane.frame.rows[1], .shape = undefined };
        out.shape = switch (region.shape) {
            .circle => |circle| .{ .circle = circle.radius },
            .polygon => |points| blk: {
                const local = try arena.alloc([2]f64, points.len);
                defer arena.free(local);
                for (local, points) |*p, index| p.* = plane.project(plan.geometry.points[index].ecef);
                var area: f64 = 0;
                for (local, 0..) |p, i| {
                    const q = local[(i + 1) % local.len];
                    area += p[0] * q[1] - q[0] * p[1];
                }
                const edges = try arena.alloc(Edge, local.len);
                for (local, edges, 0..) |p, *edge, i| {
                    const q = local[(i + 1) % local.len];
                    const dx = q[0] - p[0];
                    const dy = q[1] - p[1];
                    edge.* = .{ .start = p, .delta = .{ dx, dy }, .inverse_length = (if (area >= 0) @as(f64, 1) else -1) / @sqrt(dx * dx + dy * dy) };
                }
                break :blk .{ .polygon = edges };
            },
        };
    }
    var checks: std.ArrayList(Check) = .empty;
    var required_time: f64 = 0;
    for (plan.rules, 0..) |rule, index| {
        try continuity(arena, &checks, plan, rule);
        switch (rule.scope) {
            .time => |time| required_time = @max(required_time, time),
            .time_range => |range| required_time = @max(required_time, range[1]),
            else => {},
        }
        switch (rule.definition) {
            .quantity => |definition| switch (definition.comparison) {
                .eq => |rhs| try appendQuantity(arena, &checks, index, rule, .eq, rhs),
                .range => |range| {
                    if (range.min) |rhs| try appendQuantity(arena, &checks, index, rule, .min, rhs);
                    if (range.max) |rhs| try appendQuantity(arena, &checks, index, rule, .max, rhs);
                },
                .target, .objective => {
                    const objective = definition.comparison == .objective;
                    const reduce = if (objective) definition.comparison.objective.reduce else model.Reduce.mean_square;
                    const direction: f64 = if (objective and definition.comparison.objective.sense == .maximize) -1 else 1;
                    // The square of a norm is the sum of the squares of its components. Written so, each term is the
                    // square of a quantity that is linear in the path, which is what the solver's step models.
                    const split = objective and reduce != .value and isNorm(definition.quantity);
                    const count: usize = if (split) (if (definition.quantity == .horizontal_speed) 2 else 3) else quantities.components(definition.quantity);
                    for (0..count) |component| try checks.append(arena, .{
                        .scope = rule.scope,
                        .operation = .{ .quantity = .{ .rule = index, .comparison = if (objective) .objective else .target, .component = component, .split_norm = split } },
                        .weight = direction * rule.weight,
                        .square = !objective or reduce != .value,
                        .integral = reduce == .integral_square,
                        .average_scope = if ((definition.quantity != .duration or reduce == .integral_square) and quantities.interval(rule.scope)) rule.scope else null,
                    });
                },
            },
            .relation => |relation| switch (relation.value) {
                .follow_curve => |curve| {
                    const components: usize = if (rule.kind() == .hard and curve.tolerance > 0) 1 else 3;
                    for (0..components) |component| try checks.append(arena, .{
                        .scope = rule.scope,
                        .operation = .{ .curve = .{ .rule = index, .component = component } },
                        .equality = curve.tolerance == 0,
                        .weight = rule.weight,
                        .average_scope = if (quantities.interval(rule.scope)) rule.scope else null,
                    });
                },
                .inside_region => |index_of_region| {
                    const count: usize = switch (regions[index_of_region].shape) {
                        .circle => 1,
                        .polygon => |edges| edges.len,
                    };
                    for (0..count) |edge| try checks.append(arena, .{
                        .scope = rule.scope,
                        .operation = .{ .region = .{ .rule = index, .edge = edge } },
                        .weight = rule.weight,
                        .average_scope = if (quantities.interval(rule.scope)) rule.scope else null,
                    });
                },
            },
        }
        if (courseAtEvent(rule)) try checks.append(arena, .{ .scope = rule.scope, .operation = .{ .ahead = index } });
    }
    try checks.append(arena, .{ .scope = .{ .time = 0 }, .operation = .{ .coverage = required_time } });
    try checks.append(arena, .{ .scope = .{ .time = 0 }, .operation = .maximum_duration });
    return .{ .plan = plan, .checks = checks.items, .regions = regions, .curves = curves };
}

pub fn value(comptime K: type, prepared: *const Prepared, rhs: model.Value, sampler: anytype) [3]K.Number {
    const A = K.Arithmetic;
    return switch (rhs) {
        .scalar => |v| @splat(A.constant(v)),
        .vector => |v| K.vector(v.toArray()),
        .point => |index| K.vector(prepared.plan.geometry.points[index].ecef.toArray()),
        .event => |reference| blk: {
            var result = sampler.eventQuantity(.{ .index = reference.event, .side = reference.side }, reference.quantity);
            for (&result) |*v| v.* = A.add(A.scale(v.*, reference.factor), A.constant(reference.offset));
            break :blk result;
        },
    };
}

pub fn residual(comptime K: type, prepared: *const Prepared, check: Check, sampler: anytype, comptime mode: Mode) K.Number {
    const A = K.Arithmetic;
    return switch (check.operation) {
        .ahead => |index| A.sub(onCourse(K, sampler.point(), prepared.plan.rules[index].definition.quantity.comparison.eq.scalar).along, A.constant(rest_speed)),
        .coverage => |required| A.scale(A.sub(sampler.eventTime(prepared.plan.events.len - 1), A.constant(required)), 0.1),
        .maximum_duration => A.scale(A.sub(A.constant(shared.trajectory.max_duration_s), sampler.eventTime(prepared.plan.events.len - 1)), 0.1),
        .jump => |jump| blk: {
            if (jump.range) |range| {
                const time = A.value(sampler.eventTime(jump.event));
                if (time <= range[0] or time >= range[1]) break :blk A.constant(0);
            }
            if (quantities.directed(jump.quantity) and (sampler.atRest(.{ .index = jump.event, .side = .in }) or sampler.atRest(.{ .index = jump.event, .side = .out }))) break :blk A.constant(0);
            const before = sampler.eventQuantity(.{ .index = jump.event, .side = .in }, jump.quantity);
            const after = sampler.eventQuantity(.{ .index = jump.event, .side = .out }, jump.quantity);
            break :blk A.sub(after[jump.component], before[jump.component]);
        },
        .corner => |corner| blk: {
            if (corner.range) |range| {
                const time = A.value(sampler.eventTime(corner.event));
                if (time <= range[0] or time >= range[1]) break :blk A.constant(0);
            }
            const local = K.frame(sampler.eventQuantity(.{ .index = corner.event, .side = .in }, .position));
            const before = sampler.eventQuantity(.{ .index = corner.event, .side = .in }, .velocity_ecef);
            const after = sampler.eventQuantity(.{ .index = corner.event, .side = .out }, .velocity_ecef);
            const a = [2]K.Number{ K.dot(local.east, before), K.dot(local.north, before) };
            const b = [2]K.Number{ K.dot(local.east, after), K.dot(local.north, after) };
            break :blk if (corner.component == 0) A.sub(A.mul(a[0], b[1]), A.mul(a[1], b[0])) else A.add(A.mul(a[0], b[0]), A.mul(a[1], b[1]));
        },
        .quantity => |operation| blk: {
            const rule = prepared.plan.rules[operation.rule];
            const definition = rule.definition.quantity;
            // The optimiser holds a course at an event as no velocity across it: that is linear in the velocity,
            // which an angle is not.
            if (mode == .optimization and courseAtEvent(rule)) break :blk A.scale(onCourse(K, sampler.point(), definition.comparison.eq.scalar).across, 1 / rule.scale);
            // Where the path is at rest a quantity that hangs on the direction of travel has no value. There a row
            // of the optimiser holds nothing, and neither does a step at an event (above); what a rule's own value
            // is there the verifier decides.
            if (mode == .optimization and undirected(rule, operation.comparison, sampler)) break :blk A.constant(0);
            if (operation.split_norm) {
                const point = sampler.point();
                const state = point.state;
                const component = switch (definition.quantity) {
                    .speed3d => state.velocity[operation.component],
                    .acceleration3d => state.acceleration[operation.component],
                    .jerk3d => state.jerk[operation.component],
                    .horizontal_speed => point.horizontalVelocity()[operation.component],
                    else => unreachable,
                };
                break :blk A.scale(component, 1 / rule.scale);
            }
            if (operation.comparison == .objective) break :blk A.scale(sampler.quantity(definition.quantity, rule.scope)[operation.component], 1 / rule.scale);
            const rhs = rightHand(rule, operation.comparison).?;
            const target = value(K, prepared, rhs, sampler)[operation.component];
            // The optimiser holds a radius as the speed that goes with the turn rate: the rate may pass through zero.
            if (mode == .optimization and definition.quantity == .turn_radius and operation.comparison == .eq) {
                const point = sampler.point();
                const rate = A.scale(point.quantity(.turn_rate)[0], shared.core.constants.deg2rad(1));
                break :blk A.scale(A.sub(point.quantity(.forward_speed)[0], A.mul(target, rate)), 1 / rule.scale);
            }
            const q = sampler.quantity(definition.quantity, rule.scope)[operation.component];
            var result = A.sub(q, target);
            if (definition.quantity == .course and (operation.comparison == .eq or operation.comparison == .target)) result = A.sub(result, A.constant(360 * @floor((A.value(result) + 180) / 360)));
            if (isNorm(definition.quantity) and rule.kind() == .hard and A.value(target) >= 0) {
                const magnitude = switch (rhs) {
                    .scalar => |v| @max(rule.scale, @abs(v)),
                    else => rule.scale,
                };
                result = A.scale(A.sub(A.mul(q, q), A.mul(target, target)), 1 / magnitude);
            }
            if (operation.comparison == .max) result = A.neg(result);
            break :blk A.scale(result, 1 / rule.scale);
        },
        .curve => |operation| blk: {
            const rule = prepared.plan.rules[operation.rule];
            const curve = rule.definition.relation.value.follow_curve;
            const state = sampler.point().state;
            const reference = curveAt(K, prepared.curves[curve.curve], sampler.progress(operation.rule));
            var delta: [3]K.Number = undefined;
            for (&delta, state.position, reference) |*d, p, r| d.* = A.sub(p, r);
            if (rule.kind() == .hard and curve.tolerance > 0) break :blk A.scale(A.sub(A.constant(curve.tolerance * curve.tolerance), K.normSquared(delta)), 1 / (rule.scale * @max(rule.scale, curve.tolerance)));
            break :blk A.scale(delta[operation.component], 1 / rule.scale);
        },
        .region => |operation| blk: {
            const rule = prepared.plan.rules[operation.rule];
            break :blk A.scale(regionMargin(K, prepared.regions[rule.definition.relation.value.inside_region], operation.edge, sampler.point().state.position), 1 / rule.scale);
        },
    };
}

/// Whether a rule asks for a direction of travel where the path is at rest: at the sampler's point, or at the event
/// its value refers to.
fn undirected(rule: model.Rule, comparison: Comparison, sampler: anytype) bool {
    if (quantities.directed(rule.definition.quantity.quantity) and sampler.point().atRest()) return true;
    const rhs = rightHand(rule, comparison) orelse return false;
    return rhs == .event and quantities.directed(rhs.event.quantity) and sampler.atRest(.{ .index = rhs.event.event, .side = rhs.event.side });
}

/// A hard course of a stated number at an event.
fn courseAtEvent(rule: model.Rule) bool {
    if (rule.scope != .event or rule.definition != .quantity) return false;
    const definition = rule.definition.quantity;
    return definition.quantity == .course and definition.comparison == .eq and definition.comparison.eq == .scalar;
}

/// The horizontal velocity at a point along a course, given in degrees, and across it.
fn onCourse(comptime K: type, point: *K.Point, course: f64) struct { along: K.Number, across: K.Number } {
    const A = K.Arithmetic;
    const velocity = point.horizontalVelocity();
    const radians = shared.core.constants.deg2rad(course);
    return .{
        .along = A.add(A.scale(velocity[0], @sin(radians)), A.scale(velocity[1], @cos(radians))),
        .across = A.sub(A.scale(velocity[0], @cos(radians)), A.scale(velocity[1], @sin(radians))),
    };
}

pub fn rightHand(rule: model.Rule, comparison: Comparison) ?model.Value {
    return switch (rule.definition.quantity.comparison) {
        .eq, .target => |v| v,
        .range => |range| if (comparison == .min) range.min else range.max,
        .objective => null,
    };
}

pub fn isNorm(quantity: model.Quantity) bool {
    return quantity == .speed3d or quantity == .horizontal_speed or quantity == .acceleration3d or quantity == .jerk3d;
}

/// A constraint row that is a bound less the squared norm of a vector (a maximum of a norm, a corridor about a
/// guide, a circle) curves: its second derivative is minus `factor` times the square of that vector's Jacobian.
/// `count` is the vector's length, zero for every other constraint row.
pub const Bend = struct { count: usize = 0, factor: f64 = 0 };

pub fn bend(prepared: *const Prepared, check: Check) Bend {
    switch (check.operation) {
        .quantity => |operation| {
            const rule = prepared.plan.rules[operation.rule];
            const quantity = rule.definition.quantity.quantity;
            if (operation.split_norm or operation.comparison != .max or !isNorm(quantity)) return .{};
            const bound = switch (rightHand(rule, .max).?) {
                .scalar => |v| v,
                else => return .{},
            };
            if (!(bound >= 0)) return .{};
            return .{ .count = if (quantity == .horizontal_speed) 2 else 3, .factor = 2 / (@max(rule.scale, bound) * rule.scale) };
        },
        .curve => |operation| {
            const rule = prepared.plan.rules[operation.rule];
            const tolerance = rule.definition.relation.value.follow_curve.tolerance;
            if (tolerance <= 0) return .{};
            return .{ .count = 3, .factor = 2 / (rule.scale * @max(rule.scale, tolerance)) };
        },
        .region => |operation| {
            const rule = prepared.plan.rules[operation.rule];
            return switch (prepared.regions[rule.definition.relation.value.inside_region].shape) {
                .circle => |radius| .{ .count = 2, .factor = 2 / (@max(1, radius) * rule.scale) },
                .polygon => .{},
            };
        },
        else => return .{},
    }
}

/// The vector of a row that curves (see `bend`).
pub fn bent(comptime K: type, prepared: *const Prepared, check: Check, sampler: anytype) [3]K.Number {
    const A = K.Arithmetic;
    const point = sampler.point();
    switch (check.operation) {
        .quantity => |operation| switch (prepared.plan.rules[operation.rule].definition.quantity.quantity) {
            .speed3d => return point.state.velocity,
            .acceleration3d => return point.state.acceleration,
            .jerk3d => return point.state.jerk,
            else => {
                const horizontal = point.horizontalVelocity();
                return .{ horizontal[0], horizontal[1], A.constant(0) };
            },
        },
        .curve => |operation| {
            const curve = prepared.plan.rules[operation.rule].definition.relation.value.follow_curve;
            const reference = curveAt(K, prepared.curves[curve.curve], sampler.progress(operation.rule));
            var delta: [3]K.Number = undefined;
            for (&delta, point.state.position, reference) |*d, p, r| d.* = A.sub(p, r);
            return delta;
        },
        .region => |operation| {
            const region = prepared.regions[prepared.plan.rules[operation.rule].definition.relation.value.inside_region];
            var delta: [3]K.Number = undefined;
            for (&delta, point.state.position, region.origin) |*d, p, origin| d.* = A.sub(p, A.constant(origin));
            return .{ K.dot(K.vector(region.east), delta), K.dot(K.vector(region.north), delta), A.constant(0) };
        },
        else => unreachable,
    }
}

pub fn curveAt(comptime K: type, curve: Curve, progress: K.Number) [3]K.Number {
    const A = K.Arithmetic;
    const count = if (curve.kind == .bezier) (curve.points.len - 1) / 3 else curve.points.len - 1;
    const scaled = A.scale(progress, @floatFromInt(count));
    const piece: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count - 1)), @max(0, @floor(A.value(scaled)))));
    const u = A.sub(scaled, A.constant(@floatFromInt(piece)));
    const start = if (curve.kind == .bezier) piece * 3 else piece;
    const order: usize = if (curve.kind == .bezier) 3 else 1;
    var points: [4][3]K.Number = undefined;
    for (0..order + 1) |i| points[i] = K.vector(curve.points[start + i]);
    var level = order;
    while (level > 0) : (level -= 1) for (0..level) |i| {
        for (0..3) |axis| points[i][axis] = A.add(points[i][axis], A.mul(A.sub(points[i + 1][axis], points[i][axis]), u));
    };
    return points[0];
}

fn regionMargin(comptime K: type, region: Region, edge_index: usize, position: [3]K.Number) K.Number {
    const A = K.Arithmetic;
    var delta: [3]K.Number = undefined;
    for (&delta, position, region.origin) |*d, p, origin| d.* = A.sub(p, A.constant(origin));
    const east = K.dot(K.vector(region.east), delta);
    const north = K.dot(K.vector(region.north), delta);
    return switch (region.shape) {
        .circle => |radius| A.scale(A.sub(A.sub(A.constant(radius * radius), A.mul(east, east)), A.mul(north, north)), 1 / @max(1, radius)),
        .polygon => |edges| blk: {
            const edge = edges[edge_index];
            break :blk A.scale(A.sub(A.scale(A.sub(north, A.constant(edge.start[1])), edge.delta[0]), A.scale(A.sub(east, A.constant(edge.start[0])), edge.delta[1])), edge.inverse_length);
        },
    };
}

fn appendQuantity(arena: std.mem.Allocator, checks: *std.ArrayList(Check), index: usize, rule: model.Rule, comparison: Comparison, rhs: model.Value) std.mem.Allocator.Error!void {
    const quantity = rule.definition.quantity.quantity;
    const zero = isNorm(quantity) and (comparison == .eq or comparison == .max) and rhs == .scalar and rhs.scalar == 0;
    const count = if (zero) (if (quantity == .horizontal_speed) @as(usize, 2) else 3) else quantities.components(quantity);
    for (0..count) |component| try checks.append(arena, .{ .scope = rule.scope, .operation = .{ .quantity = .{ .rule = index, .comparison = comparison, .component = component, .split_norm = zero } }, .equality = comparison == .eq or zero });
}

fn continuity(arena: std.mem.Allocator, checks: *std.ArrayList(Check), plan: *const model.Plan, rule: model.Rule) std.mem.Allocator.Error!void {
    if (rule.kind() != .hard or rule.definition != .quantity or !quantities.interval(rule.scope)) return;
    const quantity = rule.definition.quantity.quantity;
    const turning = quantity == .lateral_acceleration or quantity == .turn_rate or quantity == .turn_radius;
    const derivatives: []const model.Quantity = switch (quantity) {
        .acceleration3d, .acceleration_ecef => &.{.velocity_ecef},
        .jerk3d => &.{ .velocity_ecef, .acceleration_ecef },
        .forward_acceleration => &.{.forward_speed},
        .forward_jerk => &.{ .forward_speed, .forward_acceleration },
        .vertical_acceleration => &.{.climb_rate},
        else => if (turning) &.{} else return,
    };
    for (1..plan.events.len - 1) |event| {
        const included = switch (rule.scope) {
            .all => true,
            .between => |events| event > events[0] and event < events[1],
            .time_range => true,
            else => false,
        };
        if (!included) continue;
        const range = if (rule.scope == .time_range) rule.scope.time_range else null;
        if (turning and plan.events[event].continuity == .c0) for (0..2) |component| {
            try checks.append(arena, .{ .scope = .{ .event = .{ .index = event } }, .operation = .{ .corner = .{ .event = event, .quantity = .velocity_ecef, .component = component, .range = range } }, .equality = component == 0 });
        };
        for (derivatives) |derivative| {
            if (plan.events[event].continuity == .c2) continue;
            if (plan.events[event].continuity == .c1 and (derivative == .velocity_ecef or derivative == .forward_speed or derivative == .climb_rate)) continue;
            for (0..quantities.components(derivative)) |component| try checks.append(arena, .{ .scope = .{ .event = .{ .index = event } }, .operation = .{ .jump = .{ .event = event, .quantity = derivative, .component = component, .range = range } }, .equality = true });
        }
    }
}
