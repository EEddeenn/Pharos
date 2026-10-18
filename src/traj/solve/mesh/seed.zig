const std = @import("std");
const shared = @import("shared");
const model = @import("../../plan.zig").model;
const geometry = @import("../../plan.zig").geometry;
const mesh = @import("../mesh.zig");
const Vector = model.Vector;
const trajectory = shared.trajectory;
const Jet = @import("../kernel.zig").Scalar.Jet;
const Error = mesh.Error;
const min_duration = mesh.min_duration;
const zero: [3]f64 = .{ 0, 0, 0 };
const sectionSpan = mesh.sectionSpan;
const literalPosition = mesh.literalPosition;
const zeroRule = mesh.zeroRule;

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
    for (plan.rules) |rule| {
        if (rule.definition != .relation or rule.definition.relation.value != .follow_curve) continue;
        const span = sectionSpan(rule.scope, plan.sections.len) orelse continue;
        const follow = rule.definition.relation.value.follow_curve;
        const rank: u8 = if (rule.kind() == .hard) 3 else 1;
        for ([_]usize{ span[0], span[1] }, [_]f64{ follow.from, follow.to }) |index, parameter| {
            if (priority[index] >= rank) continue;
            positions[index] = geometry.curve(plan.geometry, follow.curve, parameter).position;
            priority[index] = rank;
        }
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
        before.* = .{ .position = position.?.toArray(), .velocity = (if (plan.events[i].continuity == .c0) v_in else velocity).toArray(), .acceleration = zero };
        after.* = .{ .position = position.?.toArray(), .velocity = (if (plan.events[i].continuity == .c0) v_out else velocity).toArray(), .acceleration = zero };
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
    try applyAnchors(arena, plan, durations, locked);
    const before = try arena.alloc(f64, durations.len);
    for (0..plan.events.len + 1) |_| {
        @memcpy(before, durations);
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
        for (before, durations) |old, new| {
            if (@abs(new - old) > 1e-13 * @max(1, @abs(old))) break;
        } else break;
    }
    try applyAnchors(arena, plan, durations, locked);
}

fn applyAnchors(arena: std.mem.Allocator, plan: *const model.Plan, durations: []f64, locked: []const bool) std.mem.Allocator.Error!void {
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
    var previous_event: usize = 0;
    var previous_time: f64 = 0;
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

fn finiteVector(value: Vector) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z);
}
