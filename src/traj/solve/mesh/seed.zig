const std = @import("std");
const shared = @import("shared");
const model = @import("../../plan.zig").model;
const mesh = @import("../mesh.zig");
const Vector = model.Vector;
const trajectory = shared.trajectory;
const Jet = @import("../kernel.zig").Scalar.Jet;
const Error = mesh.Error;
const time_scale = mesh.time_scale;
const min_duration = mesh.min_duration;
const zero: [3]f64 = .{ 0, 0, 0 };
const sectionSpan = mesh.sectionSpan;
const literalPosition = mesh.literalPosition;
const zeroRule = mesh.zeroRule;

pub fn heading(arena: std.mem.Allocator, plan: *const model.Plan, built: *mesh.Build) std.mem.Allocator.Error!void {
    const priority = try arena.alloc(u8, built.x.len);
    @memset(priority, 0);
    const selected = try arena.alloc(bool, built.mesh.nodes.len);
    const times = try arena.alloc(f64, built.mesh.durations.len + 1);
    times[0] = 0;
    for (built.mesh.durations, 0..) |column, section| times[section + 1] = times[section] + built.x[column] * time_scale;
    for (plan.initial_guess.states) |guess| if (guess.course != null) {
        priority[built.mesh.nodes[built.mesh.event_out[guess.event]].variables[9]] = 2;
    };
    for ([_]model.Quantity{ .course, .turn_radius, .turn_rate }) |quantity| {
        for (plan.rules) |rule| {
            if (rule.kind() == .objective or rule.definition != .quantity or rule.definition.quantity.quantity != quantity) continue;
            const rank: u8 = if (rule.kind() == .hard) 3 else 1;
            selectNodes(built, times, rule.scope, selected);
            for (built.mesh.nodes, selected, 0..) |node, included, index| {
                if (!included) continue;
                const component: usize = if (quantity == .course) 9 else 10;
                const column = node.variables[component];
                if (rank < priority[column]) continue;
                const state = mesh.readNode(&built.mesh, built.x, index);
                const forward = forwardSpeed(state);
                const current = switch (quantity) {
                    .course => shared.core.constants.rad2deg(state.course),
                    .turn_rate => shared.core.constants.rad2deg(state.turn_rate),
                    .turn_radius => if (state.turn_rate != 0) forward / state.turn_rate else 0,
                    else => unreachable,
                };
                const value = seedComparison(rule.definition.quantity, current, quantity == .turn_radius) orelse continue;
                var radians = if (quantity == .turn_radius) blk: {
                    if (value == 0 or forward == 0) continue;
                    break :blk forward / value;
                } else shared.core.constants.deg2rad(value);
                if (quantity == .course and (rule.definition.quantity.comparison == .eq or rule.definition.quantity.comparison == .target)) radians = state.course + angleDifference(radians - state.course);
                if (!std.math.isFinite(radians)) continue;
                built.x[column] = std.math.clamp(radians / built.mesh.scales[component], built.lower[column], built.upper[column]);
                priority[column] = rank;
            }
        }
    }
    for (built.mesh.cells) |cell| {
        const a = built.mesh.nodes[cell.left].variables;
        const b = built.mesh.nodes[cell.right].variables;
        if (priority[b[9]] != 0 or (priority[a[10]] == 0 and priority[b[10]] == 0)) continue;
        const duration = built.x[built.mesh.durations[cell.section]] * time_scale * (cell.end - cell.start);
        const rate = (built.x[a[10]] + built.x[b[10]]) * built.mesh.scales[10] / 2;
        const course = built.x[a[9]] * built.mesh.scales[9] + duration * rate;
        built.x[b[9]] = std.math.clamp(course / built.mesh.scales[9], built.lower[b[9]], built.upper[b[9]]);
    }
}

fn seedComparison(rule: model.QuantityRule, current: f64, nonzero: bool) ?f64 {
    const result = switch (rule.comparison) {
        .eq, .target => |value| if (value == .scalar) value.scalar else return null,
        .range => |range| blk: {
            const minimum = if (range.min) |value| if (value == .scalar) value.scalar else return null else -std.math.inf(f64);
            const maximum = if (range.max) |value| if (value == .scalar) value.scalar else return null else std.math.inf(f64);
            if (minimum > maximum) return null;
            const bounded = std.math.clamp(current, minimum, maximum);
            if (!nonzero or bounded != 0) break :blk bounded;
            if (std.math.isFinite(minimum) and std.math.isFinite(maximum)) {
                const middle = minimum / 2 + maximum / 2;
                break :blk if (middle != 0) middle else if (maximum != 0) maximum else minimum;
            }
            if (std.math.isFinite(minimum) and minimum != 0) break :blk minimum;
            if (std.math.isFinite(maximum) and maximum != 0) break :blk maximum;
            break :blk @as(f64, if (maximum <= 0) -1 else 1);
        },
        .objective => return null,
    };
    return if (std.math.isFinite(result) and (!nonzero or result != 0)) result else null;
}

fn selectNodes(built: *const mesh.Build, times: []const f64, scope: model.Scope, selected: []bool) void {
    const topology = &built.mesh;
    @memset(selected, false);
    if (scope == .event) {
        const event = scope.event;
        const index = if (event.side == .in) topology.event_in[event.index] else topology.event_out[event.index];
        selected[index] = true;
        return;
    }
    if (sectionSpan(scope, topology.durations.len)) |span| {
        const begin = topology.sections[span[0]].first_cell;
        const end = topology.sections[span[1] - 1].end_cell;
        for (topology.cells[begin..end]) |cell| {
            selected[cell.left] = true;
            selected[cell.right] = true;
        }
        return;
    }
    for (topology.sections, 0..) |_, section| {
        const start = times[section];
        const duration = built.x[topology.durations[section]] * time_scale;
        for (topology.sectionCells(section)) |cell| {
            const begin = start + duration * cell.start;
            const end = start + duration * cell.end;
            switch (scope) {
                .time => |at| if (at >= begin and at <= end) {
                    selected[cell.left] = true;
                    selected[cell.right] = true;
                    return;
                },
                .time_range => |range| {
                    if (range[0] == range[1]) {
                        if (range[0] >= begin and range[0] <= end) {
                            selected[cell.left] = true;
                            selected[cell.right] = true;
                            return;
                        }
                    } else if (end > range[0] and begin < range[1]) {
                        selected[cell.left] = true;
                        selected[cell.right] = true;
                    }
                },
                else => unreachable,
            }
        }
    }
}

fn forwardSpeed(state: Jet) f64 {
    const enu = shared.core.coord.EnuFrame.at(shared.core.coord.ecefToLla(Vector.fromArray(state.position))).toEnu(Vector.fromArray(state.velocity));
    return enu.east * @sin(state.course) + enu.north * @cos(state.course);
}

pub fn initial(arena: std.mem.Allocator, plan: *const model.Plan, incoming: []Jet, outgoing: []Jet, durations: []f64) Error!void {
    const positions = try arena.alloc(?Vector, plan.events.len);
    const priority = try arena.alloc(u8, plan.events.len);
    const resting = try arena.alloc(bool, plan.sections.len);
    @memset(positions, null);
    @memset(priority, 0);
    @memset(resting, false);
    for (plan.initial_guess.states) |guess| {
        const position = guess.ecef orelse continue;
        positions[guess.event] = position;
        priority[guess.event] = 2;
    }
    for (plan.rules) |rule| {
        if (rule.kind() != .hard or rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        if (!(q.quantity == .speed3d and zeroRule(q)) and literalPosition(plan, q) == null) continue;
        const span = sectionSpan(rule.scope, plan.sections.len) orelse continue;
        @memset(resting[span[0]..span[1]], true);
    }
    for (0..plan.events.len) |_| {
        for (plan.rules) |rule| {
            if (rule.definition != .quantity or rule.kind() == .objective) continue;
            const q = rule.definition.quantity;
            if (q.quantity != .position) continue;
            const value = comparisonValue(q) orelse continue;
            const position = positionValue(plan, positions, value) orelse continue;
            const rank: u8 = if (rule.kind() == .hard) 3 else 1;
            if (rule.scope == .event) {
                const index = rule.scope.event.index;
                if (priority[index] <= rank) {
                    positions[index] = position;
                    priority[index] = rank;
                }
            } else if (sectionSpan(rule.scope, plan.sections.len)) |span| {
                for (span[0]..span[1] + 1) |index| if (priority[index] <= rank) {
                    positions[index] = position;
                    priority[index] = rank;
                };
            }
        }
        mergeRestPositions(positions, priority, resting);
    }
    var first: ?usize = null;
    for (positions, 0..) |p, i| if (p != null) {
        first = i;
        break;
    };
    if (first) |start| {
        @memset(positions[0..start], positions[start]);
        var left = start;
        for (start + 1..positions.len) |right| {
            const end = positions[right] orelse continue;
            const begin = positions[left].?;
            for (left + 1..right) |i| {
                const u = @as(f64, @floatFromInt(i - left)) / @as(f64, @floatFromInt(right - left));
                positions[i] = begin.add(end.sub(begin).scale(u));
            }
            left = right;
        }
        @memset(positions[left + 1 ..], positions[left]);
    } else {
        const fallback = if (plan.geometry.points.len > 0) plan.geometry.points[0].ecef else shared.core.coord.llaToEcef(.{ .lat_rad = 0, .lon_rad = 0, .height_m = 0 });
        @memset(positions, fallback);
    }
    mergeRestPositions(positions, priority, resting);
    for (durations, 0..) |*duration, i| duration.* = std.math.clamp(positions[i + 1].?.sub(positions[i].?).norm() / 10, 1, trajectory.max_duration_s);
    try seedTimes(arena, plan, durations);

    for (incoming, outgoing, positions, 0..) |*before, *after, position, i| {
        if (!finiteVector(position.?)) return error.InvalidMesh;
        const v_in = if (i > 0) position.?.sub(positions[i - 1].?).divide(durations[i - 1]) else positions[1].?.sub(position.?).divide(durations[0]);
        const v_out = if (i < durations.len) positions[i + 1].?.sub(position.?).divide(durations[i]) else v_in;
        const velocity = if (i == 0) v_out else if (i == durations.len) v_in else v_in.scale(durations[i]).add(v_out.scale(durations[i - 1])).divide(durations[i - 1] + durations[i]);
        before.* = .{ .position = position.?.toArray(), .velocity = (if (plan.events[i].continuity == .c0) v_in else velocity).toArray(), .acceleration = zero, .course = 0, .turn_rate = 0 };
        after.* = .{ .position = position.?.toArray(), .velocity = (if (plan.events[i].continuity == .c0) v_out else velocity).toArray(), .acceleration = zero, .course = 0, .turn_rate = 0 };
    }
    for (plan.initial_guess.states) |guess| {
        if (guess.velocity_ecef) |velocity| {
            incoming[guess.event].velocity = velocity.toArray();
            outgoing[guess.event].velocity = velocity.toArray();
        }
        if (guess.acceleration_ecef) |acceleration| {
            incoming[guess.event].acceleration = acceleration.toArray();
            outgoing[guess.event].acceleration = acceleration.toArray();
        }
    }
    for (plan.rules) |rule| {
        if (rule.kind() != .hard or rule.scope != .event or rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        const event = rule.scope.event;
        if (q.quantity == .speed3d and zeroRule(q)) {
            const shared_velocity = plan.events[event.index].continuity != .c0 or event.index == 0 or event.index + 1 == incoming.len;
            if (event.side == .in or shared_velocity) incoming[event.index].velocity = zero;
            if (event.side == .out or shared_velocity) outgoing[event.index].velocity = zero;
        }
    }
    for (resting, 0..) |rest, i| if (rest) {
        outgoing[i].velocity = zero;
        incoming[i + 1].velocity = zero;
        if (i == 0 or plan.events[i].continuity != .c0) incoming[i].velocity = zero;
        if (i + 2 == incoming.len or plan.events[i + 1].continuity != .c0) outgoing[i + 1].velocity = zero;
        outgoing[i].acceleration = zero;
        incoming[i + 1].acceleration = zero;
        if (i == 0 or plan.events[i].continuity == .c2) incoming[i].acceleration = zero;
        if (i + 2 == incoming.len or plan.events[i + 1].continuity == .c2) outgoing[i + 1].acceleration = zero;
    };
    var previous_course: f64 = 0;
    for (incoming, outgoing, 0..) |*before, *after, i| {
        var direction = Vector.fromArray(after.velocity);
        if (horizontalNorm(Vector.fromArray(after.position), direction) < 1e-6) direction = Vector.fromArray(before.velocity);
        if (horizontalNorm(Vector.fromArray(after.position), direction) < 1e-6) {
            for (0..durations.len) |distance| {
                if (i + distance < durations.len) {
                    direction = positions[i + distance + 1].?.sub(positions[i + distance].?);
                    if (horizontalNorm(Vector.fromArray(after.position), direction) >= 1e-6) break;
                }
                if (distance < i) {
                    direction = positions[i - distance].?.sub(positions[i - distance - 1].?);
                    if (horizontalNorm(Vector.fromArray(after.position), direction) >= 1e-6) break;
                }
            }
        }
        const enu = shared.core.coord.EnuFrame.at(shared.core.coord.ecefToLla(Vector.fromArray(after.position))).toEnu(direction);
        var course = if (std.math.hypot(enu.east, enu.north) >= 1e-6) std.math.atan2(enu.east, enu.north) else previous_course;
        course = previous_course + angleDifference(course - previous_course);
        for (plan.initial_guess.states) |guess| if (guess.event == i) {
            if (guess.course) |value| course = shared.core.constants.deg2rad(value);
        };
        before.course = course;
        after.course = course;
        previous_course = course;
    }
}

fn mergeRestPositions(positions: []?Vector, priority: []u8, resting: []const bool) void {
    var first: usize = 0;
    while (first < positions.len) {
        var last = first;
        while (last < resting.len and resting[last]) last += 1;
        var chosen: ?Vector = null;
        var rank: u8 = 0;
        for (first..last + 1) |i| if (positions[i] != null and (chosen == null or priority[i] > rank)) {
            chosen = positions[i];
            rank = priority[i];
        };
        if (chosen != null) {
            @memset(positions[first .. last + 1], chosen);
            @memset(priority[first .. last + 1], rank);
        }
        first = last + 1;
    }
}

fn seedTimes(arena: std.mem.Allocator, plan: *const model.Plan, durations: []f64) std.mem.Allocator.Error!void {
    const locked = try arena.alloc(bool, durations.len);
    @memset(locked, false);
    var previous_event: usize = 0;
    var previous_time: f64 = 0;
    for (plan.initial_guess.event_times, 0..) |entry, i| {
        const value = entry orelse continue;
        if (i == 0 or !std.math.isFinite(value) or value <= previous_time) continue;
        adjustSpan(durations, locked, previous_event, i, value - previous_time);
        previous_event = i;
        previous_time = eventTime(durations, i);
    }
    for (plan.rules) |rule| {
        if (rule.kind() != .hard or rule.scope != .section or rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        if (q.quantity != .duration or q.comparison != .eq) continue;
        const value = scalarValue(q.comparison.eq, durations) orelse continue;
        durations[rule.scope.section] = boundedDuration(value);
        locked[rule.scope.section] = true;
    }
    for (0..plan.events.len + 1) |_| {
        for ([_]model.RuleKind{ .target, .hard }) |kind| for (plan.rules) |rule| {
            if (rule.kind() != kind or rule.definition != .quantity) continue;
            const q = rule.definition.quantity;
            if (q.quantity != .time and q.quantity != .duration) continue;
            if (q.quantity == .duration) {
                const span = sectionSpan(rule.scope, durations.len) orelse continue;
                const current = eventTime(durations, span[1]) - eventTime(durations, span[0]);
                const value = scalarComparison(q, durations, current) orelse continue;
                if (rule.kind() == .hard and rule.scope == .section and q.comparison == .eq) {
                    durations[span[0]] = boundedDuration(value);
                } else adjustSpan(durations, locked, span[0], span[1], value);
            } else if (rule.scope == .event) {
                const index = rule.scope.event.index;
                if (index == 0) continue;
                if (comparisonValue(q)) |value| {
                    if (value == .event and value.event.quantity == .time and value.event.factor == 1 and value.event.event < index) {
                        adjustSpan(durations, locked, value.event.event, index, value.event.offset);
                        continue;
                    }
                }
                const value = scalarComparison(q, durations, eventTime(durations, index)) orelse continue;
                adjustSpan(durations, locked, 0, index, value);
            }
        };
    }
    const anchors = try arena.alloc(?f64, plan.events.len);
    const priority = try arena.alloc(u8, plan.events.len);
    @memset(anchors, null);
    @memset(priority, 0);
    for (plan.initial_guess.event_times, 0..) |value, i| {
        if (value) |time| if (std.math.isFinite(time) and time >= 0) {
            anchors[i] = time;
            priority[i] = 2;
        };
    }
    anchors[0] = 0;
    priority[0] = 4;
    for (0..plan.events.len + 1) |_| for (plan.rules) |rule| {
        if (rule.kind() == .objective or rule.scope != .event or rule.definition != .quantity) continue;
        const q = rule.definition.quantity;
        if (q.quantity != .time) continue;
        const index = rule.scope.event.index;
        const value = comparisonValue(q) orelse continue;
        const rank: u8 = if (rule.kind() == .hard) 3 else 1;
        switch (value) {
            .scalar => |time| setTimeAnchor(anchors, priority, index, time, rank),
            .event => |reference| {
                if (reference.quantity != .time) continue;
                if (anchors[index] != null and reference.factor != 0 and
                    (anchors[reference.event] == null or priority[index] > priority[reference.event]))
                {
                    setTimeAnchor(anchors, priority, reference.event, (anchors[index].? - reference.offset) / reference.factor, rank);
                } else if (anchors[reference.event]) |time| {
                    setTimeAnchor(anchors, priority, index, time * reference.factor + reference.offset, rank);
                }
            },
            else => {},
        }
    };
    previous_event = 0;
    previous_time = 0;
    for (anchors[1..], 1..) |anchor, i| {
        const time = anchor orelse continue;
        if (time <= previous_time) continue;
        adjustSpan(durations, locked, previous_event, i, time - previous_time);
        previous_event = i;
        previous_time = eventTime(durations, i);
    }
}

fn setTimeAnchor(anchors: []?f64, priority: []u8, index: usize, time: f64, rank: u8) void {
    if (!std.math.isFinite(time) or time < 0 or rank < priority[index]) return;
    anchors[index] = time;
    priority[index] = rank;
}

fn adjustSpan(durations: []f64, locked: []const bool, first: usize, end: usize, target: f64) void {
    if (first >= end or !std.math.isFinite(target)) return;
    var fixed: f64 = 0;
    var weight: f64 = 0;
    var count: usize = 0;
    for (first..end) |i| {
        if (locked[i]) {
            fixed += durations[i];
        } else {
            weight += @max(0, durations[i] - min_duration);
            count += 1;
        }
    }
    if (count == 0) return;
    const free = @max(0, target - fixed - @as(f64, @floatFromInt(count)) * min_duration);
    for (first..end) |i| if (!locked[i]) {
        const fraction = if (weight > 0) @max(0, durations[i] - min_duration) / weight else 1 / @as(f64, @floatFromInt(count));
        durations[i] = boundedDuration(min_duration + free * fraction);
    };
}

fn scalarComparison(rule: model.QuantityRule, durations: []const f64, current: f64) ?f64 {
    return switch (rule.comparison) {
        .eq, .target => |value| scalarValue(value, durations),
        .range => |range| blk: {
            const lower = if (range.min) |value| scalarValue(value, durations) orelse break :blk null else -std.math.inf(f64);
            const upper = if (range.max) |value| scalarValue(value, durations) orelse break :blk null else std.math.inf(f64);
            if (lower > upper) break :blk null;
            break :blk std.math.clamp(current, lower, upper);
        },
        .objective => null,
    };
}

fn scalarValue(value: model.Value, durations: []const f64) ?f64 {
    const result = switch (value) {
        .scalar => |scalar| scalar,
        .event => |reference| blk: {
            const source = switch (reference.quantity) {
                .time => eventTime(durations, reference.event),
                else => break :blk null,
            };
            break :blk source * reference.factor + reference.offset;
        },
        else => null,
    } orelse return null;
    return if (std.math.isFinite(result)) result else null;
}

fn positionValue(plan: *const model.Plan, positions: []const ?Vector, value: model.Value) ?Vector {
    return switch (value) {
        .vector => |vector| vector,
        .point => |index| plan.geometry.points[index].ecef,
        .event => |reference| blk: {
            if (reference.quantity != .position) break :blk null;
            const position = positions[reference.event] orelse break :blk null;
            break :blk position.scale(reference.factor).add(.{ .x = reference.offset, .y = reference.offset, .z = reference.offset });
        },
        .scalar => null,
    };
}

fn comparisonValue(rule: model.QuantityRule) ?model.Value {
    return switch (rule.comparison) {
        .eq, .target => |value| value,
        else => null,
    };
}

fn eventTime(durations: []const f64, index: usize) f64 {
    var time: f64 = 0;
    for (durations[0..index]) |duration| time += duration;
    return time;
}

fn boundedDuration(value: f64) f64 {
    return if (std.math.isFinite(value)) std.math.clamp(value, min_duration, trajectory.max_duration_s) else 1;
}

fn horizontalNorm(position: Vector, velocity: Vector) f64 {
    const enu = shared.core.coord.EnuFrame.at(shared.core.coord.ecefToLla(position)).toEnu(velocity);
    return std.math.hypot(enu.east, enu.north);
}

fn angleDifference(value: f64) f64 {
    return value - shared.core.constants.two_pi * @floor((value + std.math.pi) / shared.core.constants.two_pi);
}

fn finiteVector(value: Vector) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z);
}
