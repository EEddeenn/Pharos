const std = @import("std");
const shared = @import("shared");
const model = @import("../../plan.zig").model;
const mesh = @import("../mesh.zig");
const trajectory = shared.trajectory;
const time_scale = mesh.time_scale;
const sectionSpan = mesh.sectionSpan;
const literalPosition = mesh.literalPosition;
const zeroRule = mesh.zeroRule;

pub fn apply(arena: std.mem.Allocator, plan: *const model.Plan, built: *mesh.Build, nodes: []mesh.Node, durations: []usize) std.mem.Allocator.Error!void {
    const lower = built.lower;
    const upper = built.upper;
    const aliases = try arena.alloc(usize, built.x.len);
    for (aliases, 0..) |*parent, i| parent.* = i;
    for (plan.rules) |rule| {
        if (rule.kind() != .hard or rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        if ((q.quantity == .speed3d and zeroRule(q)) or literalPosition(plan, q) != null) {
            const span = sectionSpan(rule.scope, plan.sections.len) orelse continue;
            const begin = built.mesh.sections[span[0]].first_cell;
            const end = built.mesh.sections[span[1] - 1].end_cell;
            for (built.mesh.cells[begin..end]) |cell| {
                for (0..3) |component| mergeAlias(aliases, nodes[cell.left].variables[component], nodes[cell.right].variables[component]);
            }
        } else if (q.quantity == .position and rule.scope == .event and q.comparison == .eq and q.comparison.eq == .event) {
            const reference = q.comparison.eq.event;
            if (reference.quantity != .position or reference.factor != 1 or reference.offset != 0) continue;
            const a = built.mesh.event_out[rule.scope.event.index];
            const b = built.mesh.event_out[reference.event];
            for (0..3) |component| mergeAlias(aliases, nodes[a].variables[component], nodes[b].variables[component]);
        }
    }
    for (nodes) |*node| for (&node.variables) |*column| {
        column.* = aliasRoot(aliases, column.*);
    };

    const times = try arena.alloc(?f64, plan.events.len);
    @memset(times, null);
    times[0] = 0;
    for (plan.rules) |rule| {
        if (rule.kind() != .hard or rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        if (rule.scope == .event) {
            const event = rule.scope.event;
            const node = nodes[if (event.side == .in) built.mesh.event_in[event.index] else built.mesh.event_out[event.index]];
            switch (q.quantity) {
                .position, .velocity_ecef, .acceleration_ecef => {
                    if (q.comparison != .eq) continue;
                    const vector = switch (q.comparison.eq) {
                        .vector => |value| value,
                        .point => |index| blk: {
                            if (q.quantity != .position) continue;
                            break :blk plan.geometry.points[index].ecef;
                        },
                        else => continue,
                    };
                    const first: usize = switch (q.quantity) {
                        .position => 0,
                        .velocity_ecef => 3,
                        .acceleration_ecef => 6,
                        else => unreachable,
                    };
                    const value = if (first == 0) vector.sub(built.mesh.origin) else vector;
                    for (value.toArray(), first..) |component, axis| fixBound(built, node.variables[axis], component / built.mesh.scales[axis]);
                },
                .speed3d, .acceleration3d => if (zeroRule(q)) {
                    const first: usize = if (q.quantity == .speed3d) 3 else 6;
                    for (first..first + 3) |component| fixBound(built, node.variables[component], 0);
                },
                .time => if (q.comparison == .eq and q.comparison.eq == .scalar) {
                    const value = q.comparison.eq.scalar;
                    if (!std.math.isFinite(value) or value < 0 or value > trajectory.max_duration_s) {
                        built.inconsistent = true;
                    } else if (times[event.index]) |old| {
                        if (!sameFixed(old, value)) built.inconsistent = true;
                    } else times[event.index] = value;
                },
                else => {},
            }
        } else if (q.quantity == .duration and rule.scope == .section and q.comparison == .eq and q.comparison.eq == .scalar) {
            fixBound(built, built.mesh.durations[rule.scope.section], q.comparison.eq.scalar / time_scale);
        } else if ((q.quantity == .speed3d and zeroRule(q)) or literalPosition(plan, q) != null) {
            const span = sectionSpan(rule.scope, plan.sections.len) orelse continue;
            const position = literalPosition(plan, q);
            const begin = built.mesh.sections[span[0]].first_cell;
            const end = built.mesh.sections[span[1] - 1].end_cell;
            for (built.mesh.cells[begin..end]) |cell| {
                for ([_]usize{ cell.left, cell.right }) |node| {
                    if (position) |value| for (value.sub(built.mesh.origin).toArray(), 0..) |component, axis| {
                        fixBound(built, nodes[node].variables[axis], component / built.mesh.scales[axis]);
                    };
                    for (3..9) |component| fixBound(built, nodes[node].variables[component], 0);
                }
            }
        }
    }
    var first: usize = 0;
    for (times[1..], 1..) |time, end| {
        const finish = time orelse continue;
        const start = times[first].?;
        const span = finish - start;
        var minimum: f64 = 0;
        var maximum: f64 = 0;
        var fixed: f64 = 0;
        var free_count: usize = 0;
        var free_column: usize = 0;
        for (built.mesh.durations[first..end]) |column| {
            minimum += lower[column] * time_scale;
            maximum += upper[column] * time_scale;
            if (lower[column] == upper[column]) {
                fixed += lower[column] * time_scale;
            } else {
                free_count += 1;
                free_column = column;
            }
        }
        if ((span < minimum and !sameFixed(finish, start + minimum)) or (span > maximum and !sameFixed(finish, start + maximum))) {
            built.inconsistent = true;
        } else if (free_count == 1) {
            const value = std.math.clamp((span - fixed) / time_scale, lower[free_column], upper[free_column]);
            fixBound(built, free_column, value);
        }
        first = end;
    }
    const columns = try arena.alloc(usize, aliases.len);
    var count: usize = 0;
    for (aliases, 0..) |parent, column| {
        if (parent != column) continue;
        columns[column] = count;
        built.x[count] = std.math.clamp(built.x[column], lower[column], upper[column]);
        lower[count] = lower[column];
        upper[count] = upper[column];
        count += 1;
    }
    for (nodes) |*node| for (&node.variables) |*column| {
        column.* = columns[column.*];
    };
    for (durations) |*column| column.* = columns[column.*];
    built.x = built.x[0..count];
    built.lower = lower[0..count];
    built.upper = upper[0..count];
}

fn aliasRoot(aliases: []usize, index: usize) usize {
    var root = index;
    while (aliases[root] != root) root = aliases[root];
    var current = index;
    while (aliases[current] != current) {
        const next = aliases[current];
        aliases[current] = root;
        current = next;
    }
    return root;
}

fn mergeAlias(aliases: []usize, a: usize, b: usize) void {
    const first = aliasRoot(aliases, a);
    const second = aliasRoot(aliases, b);
    aliases[@max(first, second)] = @min(first, second);
}

fn fixBound(built: *mesh.Build, column: usize, value: f64) void {
    const lower = built.lower;
    const upper = built.upper;
    if (!std.math.isFinite(value) or
        (value < lower[column] and !sameFixed(value, lower[column])) or
        (value > upper[column] and !sameFixed(value, upper[column])))
    {
        built.inconsistent = true;
        return;
    }
    if (lower[column] == upper[column]) {
        if (!sameFixed(value, lower[column])) built.inconsistent = true;
        return;
    }
    const fixed = std.math.clamp(value, lower[column], upper[column]);
    lower[column] = fixed;
    upper[column] = fixed;
    built.x[column] = fixed;
}

fn sameFixed(a: f64, b: f64) bool {
    return @abs(a - b) <= 32 * std.math.floatEps(f64) * @max(1, @max(@abs(a), @abs(b)));
}
