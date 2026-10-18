const std = @import("std");
const shared = @import("shared");
const model = @import("../plan.zig").model;
const kernel = @import("kernel.zig");
const candidate = @import("candidate.zig");
const seed = @import("mesh/seed.zig");
const presolve = @import("mesh/presolve.zig");
const Vector = model.Vector;
const trajectory = shared.trajectory;
const Jet = kernel.Scalar.Jet;

pub const time_scale: f64 = 10;
pub const min_duration: f64 = 1e-3;
pub const Error = error{ OutOfMemory, InvalidMesh };
pub const Node = struct { variables: [9]usize };
pub const Cell = candidate.Cell;
pub const Section = candidate.Section;
pub const Mesh = struct {
    origin: Vector,
    scales: [9]f64,
    nodes: []const Node,
    cells: []const Cell,
    sections: []const Section,
    event_in: []const usize,
    event_out: []const usize,
    durations: []const usize,
};
pub const Build = struct {
    mesh: Mesh,
    x: []f64,
    lower: []f64,
    upper: []f64,
    inconsistent: bool = false,
    /// Where `inconsistent`: the hard rule whose literal value could not be taken, and the rule that had fixed the
    /// value it contradicts (each where one is known).
    conflict: [2]?usize = .{ null, null },
    /// The hard rule that gives the last event its time, where one does.
    end_rule: ?usize = null,
};

const scales = [9]f64{ 100, 100, 100, 10, 10, 10, 1, 1, 1 };

pub fn build(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, plan: *const model.Plan, counts: []const usize, previous: ?*const candidate.Path) Error!Build {
    var node_count = plan.events.len;
    var variable_count = std.math.mul(usize, node_count, 9) catch return error.InvalidMesh;
    var cell_count: usize = 0;
    for (counts) |count| {
        cell_count = std.math.add(usize, cell_count, count) catch return error.InvalidMesh;
        node_count = std.math.add(usize, node_count, count - 1) catch return error.InvalidMesh;
        const variables = std.math.mul(usize, count - 1, 9) catch return error.InvalidMesh;
        variable_count = std.math.add(usize, variable_count, variables) catch return error.InvalidMesh;
    }
    for (plan.events[1 .. plan.events.len - 1]) |event| if (event.continuity != .c2) {
        node_count = std.math.add(usize, node_count, 1) catch return error.InvalidMesh;
        variable_count = std.math.add(usize, variable_count, if (event.continuity == .c0) 6 else 3) catch return error.InvalidMesh;
    };
    variable_count = std.math.add(usize, variable_count, plan.sections.len) catch return error.InvalidMesh;

    const nodes = try result_allocator.alloc(Node, node_count);
    const cells = try result_allocator.alloc(Cell, cell_count);
    const sections = try result_allocator.alloc(Section, plan.sections.len);
    const event_in = try result_allocator.alloc(usize, plan.events.len);
    const event_out = try result_allocator.alloc(usize, plan.events.len);
    const durations = try result_allocator.alloc(usize, plan.sections.len);
    const x = try result_allocator.alloc(f64, variable_count);
    const lower = try result_allocator.alloc(f64, variable_count);
    const upper = try result_allocator.alloc(f64, variable_count);
    var next_node: usize = 0;
    var next_variable: usize = 0;
    for (plan.events, 0..) |event, i| {
        event_in[i] = next_node;
        nodes[next_node] = freshNode(&next_variable);
        next_node += 1;
        event_out[i] = event_in[i];
        if (i == 0 or i + 1 == plan.events.len or event.continuity == .c2) continue;
        event_out[i] = next_node;
        nodes[next_node] = nodes[event_in[i]];
        const first: usize = if (event.continuity == .c0) 3 else 6;
        for (first..9) |component| {
            nodes[next_node].variables[component] = next_variable;
            next_variable += 1;
        }
        next_node += 1;
    }
    var next_cell: usize = 0;
    for (counts, 0..) |count, i| {
        const first_cell = next_cell;
        var left = event_out[i];
        for (0..count) |part| {
            const right = if (part + 1 == count) event_in[i + 1] else blk: {
                const index = next_node;
                nodes[index] = freshNode(&next_variable);
                next_node += 1;
                break :blk index;
            };
            cells[next_cell] = .{
                .section = i,
                .left = left,
                .right = right,
                .start = @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(count)),
                .end = @as(f64, @floatFromInt(part + 1)) / @as(f64, @floatFromInt(count)),
            };
            next_cell += 1;
            left = right;
        }
        sections[i] = .{ .first_cell = first_cell, .end_cell = next_cell };
        durations[i] = next_variable;
        next_variable += 1;
    }
    std.debug.assert(next_variable == variable_count and next_node == node_count and next_cell == cell_count);

    var result: Build = undefined;
    {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const incoming = try temporary.alloc(Jet, plan.events.len);
        const outgoing = try temporary.alloc(Jet, plan.events.len);
        const seconds = try temporary.alloc(f64, plan.sections.len);
        if (previous) |old| {
            for (incoming, outgoing, 0..) |*before, *after, event| {
                before.* = old.event(event, .in);
                after.* = old.event(event, .out);
            }
            for (seconds, 0..) |*duration, section| duration.* = old.duration(section);
        } else {
            try seed.initial(temporary, plan, incoming, outgoing, seconds);
        }
        const origin = Vector.fromArray(incoming[0].position);
        result = .{
            .mesh = .{
                .origin = origin,
                .scales = scales,
                .nodes = nodes,
                .cells = cells,
                .sections = sections,
                .event_in = event_in,
                .event_out = event_out,
                .durations = durations,
            },
            .x = x,
            .lower = lower,
            .upper = upper,
        };
        for (nodes) |node| for (node.variables, 0..) |index, component| {
            const limit = componentLimit(component);
            const offset = if (component < 3) origin.toArray()[component] else 0;
            lower[index] = (-limit - offset) / scales[component];
            upper[index] = (limit - offset) / scales[component];
        };
        for (durations, seconds) |index, duration| {
            lower[index] = min_duration / time_scale;
            upper[index] = trajectory.max_duration_s / time_scale;
            x[index] = std.math.clamp(duration / time_scale, lower[index], upper[index]);
        }
        for (incoming, outgoing, event_in, event_out) |before, after, in_index, out_index| {
            try writeNode(&result, in_index, before);
            try writeNode(&result, out_index, after);
        }
        if (previous) |old| {
            for (cells) |cell| {
                if (cell.end == 1) continue;
                try writeNode(&result, cell.right, old.sampleSection(cell.section, cell.end));
            }
        } else {
            for (sections, 0..) |section, index| {
                const polynomial = kernel.Scalar.Cell.init(outgoing[index], incoming[index + 1], seconds[index]);
                for (cells[section.first_cell .. section.end_cell - 1]) |cell| {
                    const state = polynomial.at(cell.end);
                    try writeNode(&result, cell.right, .{ .position = state.position, .velocity = state.velocity, .acceleration = state.acceleration });
                }
            }
        }
        try presolve.apply(temporary, plan, &result, nodes, durations);
    }
    result.x = try result_allocator.realloc(x, result.x.len);
    result.lower = try result_allocator.realloc(lower, result.lower.len);
    result.upper = try result_allocator.realloc(upper, result.upper.len);
    return result;
}

fn freshNode(next: *usize) Node {
    var result: Node = undefined;
    for (&result.variables) |*index| {
        index.* = next.*;
        next.* += 1;
    }
    return result;
}

fn componentLimit(component: usize) f64 {
    return switch (component) {
        0...2 => trajectory.max_radius_m,
        3...5 => trajectory.max_speed_mps,
        6...8 => trajectory.max_acceleration_mps2,
        else => unreachable,
    };
}

fn writeNode(built: *Build, index: usize, state: Jet) Error!void {
    const p = Vector.fromArray(state.position).sub(built.mesh.origin).toArray();
    const v = state.velocity;
    const a = state.acceleration;
    const values = p ++ v ++ a;
    for (built.mesh.nodes[index].variables, values, built.mesh.scales) |column, value, scale| {
        if (!std.math.isFinite(value)) return error.InvalidMesh;
        built.x[column] = std.math.clamp(value / scale, built.lower[column], built.upper[column]);
    }
}

pub fn sectionSpan(scope: model.Scope, count: usize) ?[2]usize {
    return switch (scope) {
        .section => |index| .{ index, index + 1 },
        .between => |ends| ends,
        .all => .{ 0, count },
        else => null,
    };
}

pub fn literalPosition(plan: *const model.Plan, rule: model.QuantityRule) ?Vector {
    if (rule.quantity != .position or rule.comparison != .eq) return null;
    return switch (rule.comparison.eq) {
        .vector => |value| value,
        .point => |index| plan.geometry.points[index].ecef,
        else => null,
    };
}

pub fn zeroRule(rule: model.QuantityRule) bool {
    return switch (rule.comparison) {
        .eq => |value| value == .scalar and value.scalar == 0,
        .range => |range| if (range.max) |value| value == .scalar and value.scalar == 0 else false,
        else => false,
    };
}
