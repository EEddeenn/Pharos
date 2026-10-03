const std = @import("std");
const shared = @import("shared");
const plan_module = @import("../plan.zig");
const model = plan_module.model;
const quantities = plan_module.quantities;

pub const Comparison = enum { eq, min, max, target, objective };
pub const Mode = enum { optimization, verification };
pub const Operation = union(enum) {
    alignment,
    quantity: struct { rule: usize, comparison: Comparison, component: usize, zero_norm: bool = false },
    curve: struct { rule: usize, component: usize },
    region: struct { rule: usize, edge: usize },
    coverage: f64,
    maximum_duration,
    jump: struct { event: usize, quantity: model.Quantity, component: usize, range: ?[2]f64 = null },
};

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
    oriented: bool,
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
    const oriented = hasDirection(plan);
    var checks: std.ArrayList(Check) = .empty;
    if (oriented) try checks.append(arena, .{ .scope = .all, .operation = .alignment, .equality = true });
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
                    for (0..quantities.components(definition.quantity)) |component| try checks.append(arena, .{
                        .scope = rule.scope,
                        .operation = .{ .quantity = .{ .rule = index, .comparison = if (objective) .objective else .target, .component = component } },
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
    }
    try checks.append(arena, .{ .scope = .{ .time = 0 }, .operation = .{ .coverage = required_time } });
    try checks.append(arena, .{ .scope = .{ .time = 0 }, .operation = .maximum_duration });
    return .{ .plan = plan, .oriented = oriented, .checks = checks.items, .regions = regions, .curves = curves };
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
        .alignment => blk: {
            const point = sampler.point();
            const local = point.localFrame();
            const state = point.alignedState();
            break :blk A.scale(A.sub(A.mul(K.dot(local.east, state.velocity), A.cos(state.course)), A.mul(K.dot(local.north, state.velocity), A.sin(state.course))), 0.1);
        },
        .coverage => |required| A.scale(A.sub(sampler.eventTime(prepared.plan.events.len - 1), A.constant(required)), 0.1),
        .maximum_duration => A.scale(A.sub(A.constant(shared.trajectory.max_duration_s), sampler.eventTime(prepared.plan.events.len - 1)), 0.1),
        .jump => |jump| blk: {
            if (jump.range) |range| {
                const time = A.value(sampler.eventTime(jump.event));
                if (time <= range[0] or time >= range[1]) break :blk A.constant(0);
            }
            const before = sampler.eventQuantity(.{ .index = jump.event, .side = .in }, jump.quantity);
            const after = sampler.eventQuantity(.{ .index = jump.event, .side = .out }, jump.quantity);
            break :blk A.sub(after[jump.component], before[jump.component]);
        },
        .quantity => |operation| blk: {
            const rule = prepared.plan.rules[operation.rule];
            const definition = rule.definition.quantity;
            if (operation.zero_norm) {
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
            if (definition.quantity == .turn_radius and operation.comparison == .eq) {
                const point = sampler.point();
                const forward = point.quantity(.forward_speed)[0];
                const rate = point.alignedState().turn_rate;
                if (mode == .verification and rule.kind() == .hard) {
                    if (A.value(forward) == 0 and A.value(rate) == 0) break :blk A.constant(0);
                    break :blk A.scale(A.sub(A.div(forward, rate), target), 1 / rule.scale);
                }
                break :blk A.scale(A.sub(forward, A.mul(target, rate)), 1 / rule.scale);
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

fn curveAt(comptime K: type, curve: Curve, progress: K.Number) [3]K.Number {
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
    for (0..count) |component| try checks.append(arena, .{ .scope = rule.scope, .operation = .{ .quantity = .{ .rule = index, .comparison = comparison, .component = component, .zero_norm = zero } }, .equality = comparison == .eq or zero });
}

fn hasDirection(plan: *const model.Plan) bool {
    for (plan.initial_guess.states) |state| if (state.course != null) return true;
    for (plan.rules) |rule| {
        if (rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        if (directionQuantity(q.quantity)) return true;
        switch (q.comparison) {
            .eq, .target => |rhs| if (rhs == .event and directionQuantity(rhs.event.quantity)) return true,
            .range => |range| for ([_]?model.Value{ range.min, range.max }) |bound| {
                if (bound) |rhs| if (rhs == .event and directionQuantity(rhs.event.quantity)) return true;
            },
            .objective => {},
        }
    }
    return false;
}

fn directionQuantity(quantity: model.Quantity) bool {
    return switch (quantity) {
        .course, .turn_rate, .turn_radius, .forward_speed, .forward_acceleration, .forward_jerk, .lateral_acceleration => true,
        else => false,
    };
}

fn continuity(arena: std.mem.Allocator, checks: *std.ArrayList(Check), plan: *const model.Plan, rule: model.Rule) std.mem.Allocator.Error!void {
    if (rule.kind() != .hard or rule.definition != .quantity or !quantities.interval(rule.scope)) return;
    const derivatives: []const model.Quantity = switch (rule.definition.quantity.quantity) {
        .acceleration3d, .acceleration_ecef => &.{.velocity_ecef},
        .jerk3d => &.{ .velocity_ecef, .acceleration_ecef },
        .forward_acceleration => &.{.forward_speed},
        .forward_jerk => &.{ .forward_speed, .forward_acceleration },
        .vertical_acceleration => &.{.climb_rate},
        else => return,
    };
    for (1..plan.events.len - 1) |event| {
        const included = switch (rule.scope) {
            .all => true,
            .between => |events| event > events[0] and event < events[1],
            .time_range => true,
            else => false,
        };
        if (!included) continue;
        for (derivatives) |derivative| {
            if (plan.events[event].continuity == .c2) continue;
            if (plan.events[event].continuity == .c1 and (derivative == .velocity_ecef or derivative == .forward_speed or derivative == .climb_rate)) continue;
            for (0..quantities.components(derivative)) |component| try checks.append(arena, .{ .scope = .{ .event = .{ .index = event } }, .operation = .{ .jump = .{ .event = event, .quantity = derivative, .component = component, .range = if (rule.scope == .time_range) rule.scope.time_range else null } }, .equality = true });
        }
    }
}
