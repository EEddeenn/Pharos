const std = @import("std");
const model = @import("../../plan.zig").model;
const rules = @import("../rules.zig");
const mesh_module = @import("../mesh.zig");
const problem = @import("../problem.zig");
const kernel = @import("../kernel.zig");

const subdivisions = 4;
const QuantitySet = std.EnumSet(model.Quantity);
const CurveSample = std.meta.Child(@FieldType(problem.Curve, "samples"));
const Bounds = struct { value: f64, lower: f64, upper: f64 };
const Sampling = struct { scope: model.Scope, points: []const usize };
const LocationKey = struct { kind: enum { cell, event, time }, index: usize, value: u64 };
const Batch = struct {
    constraints: std.ArrayList(usize) = .empty,
    objectives: std.ArrayList(usize) = .empty,
    points: std.ArrayList(usize) = .empty,
};

pub fn prepare(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, prepared_rules: *const rules.Prepared, built: mesh_module.Build) std.mem.Allocator.Error!problem.Prepared {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    var compiler: Compiler = .{
        .allocator = temporary,
        .rules = prepared_rules,
        .mesh = &built.mesh,
        .base_variables = built.x.len,
        .curve_indices = try temporary.alloc(?usize, prepared_rules.plan.rules.len),
    };
    @memset(compiler.curve_indices, null);
    for (prepared_rules.plan.events, 0..) |_, event| {
        _ = try compiler.point(.{ .event = .{ .index = event, .side = .in } });
        _ = try compiler.point(.{ .event = .{ .index = event, .side = .out } });
    }
    for (prepared_rules.checks, 0..) |check, index| try compiler.check(check, index);

    const variable_count = built.x.len + compiler.variables.items.len;
    const x = try result_allocator.alloc(f64, variable_count);
    const lower = try result_allocator.alloc(f64, variable_count);
    const upper = try result_allocator.alloc(f64, variable_count);
    @memcpy(x[0..built.x.len], built.x);
    @memcpy(lower[0..built.lower.len], built.lower);
    @memcpy(upper[0..built.upper.len], built.upper);
    for (compiler.variables.items, built.x.len..) |variable, index| {
        x[index] = variable.value;
        lower[index] = variable.lower;
        upper[index] = variable.upper;
    }

    const constraints = try result_allocator.dupe(problem.Term, compiler.constraints.items);
    const objectives = try result_allocator.dupe(problem.Term, compiler.objectives.items);
    var equality_count: usize = 0;
    for (constraints, 0..) |term, index| if (term.equality) {
        std.mem.swap(problem.Term, &constraints[equality_count], &constraints[index]);
        equality_count += 1;
    };
    var columns: Columns = .{
        .allocator = temporary,
        .marks = try temporary.alloc(usize, variable_count),
        .lower = lower,
        .upper = upper,
        .mesh = &built.mesh,
    };
    @memset(columns.marks, 0);
    var constraint_column_count: usize = 0;
    for (constraints) |*term| {
        try columns.term(&compiler, term.*, false);
        term.columns = try temporary.dupe(usize, columns.items.items);
        constraint_column_count += term.columns.len;
    }
    for (objectives) |*term| {
        try columns.term(&compiler, term.*, true);
        term.columns = try result_allocator.dupe(usize, columns.items.items);
    }
    const row_offsets = try result_allocator.alloc(usize, constraints.len + 1);
    const constraint_columns = try result_allocator.alloc(usize, constraint_column_count);
    row_offsets[0] = 0;
    for (constraints, 0..) |*term, row| {
        const end = row_offsets[row] + term.columns.len;
        @memcpy(constraint_columns[row_offsets[row]..end], term.columns);
        term.columns = constraint_columns[row_offsets[row]..end];
        row_offsets[row + 1] = end;
    }

    const location_batches = try temporary.alloc(usize, compiler.locations.items.len);
    var batch_count = built.mesh.cells.len;
    for (compiler.locations.items, location_batches) |location, *index| {
        if (location == .time) {
            index.* = batch_count;
            batch_count += 1;
        } else index.* = cellIndex(&built.mesh, location);
    }
    const temporary_batches = try temporary.alloc(Batch, batch_count);
    @memset(temporary_batches, .{});
    for (constraints, 0..) |term, row| {
        const batch = &temporary_batches[location_batches[term.point]];
        try batch.constraints.append(temporary, row);
        try compiler.batchPoints(batch, term);
    }
    for (objectives, 0..) |term, index| {
        const batch = &temporary_batches[location_batches[term.point]];
        try batch.objectives.append(temporary, index);
        try compiler.batchPoints(batch, term);
    }
    var used_batches: usize = 0;
    for (temporary_batches) |batch| if (batch.constraints.items.len != 0 or batch.objectives.items.len != 0) {
        used_batches += 1;
    };
    const batches = try result_allocator.alloc(problem.Batch, used_batches);
    const duration_sections = try temporary.alloc(?usize, variable_count);
    @memset(duration_sections, null);
    for (built.mesh.durations, 0..) |column, section| duration_sections[column] = section;
    var next_batch: usize = 0;
    var max_batch_points: usize = 0;
    for (temporary_batches) |batch| {
        if (batch.constraints.items.len == 0 and batch.objectives.items.len == 0) continue;
        columns.reset();
        for (batch.constraints.items) |index| for (constraints[index].columns) |column| try columns.add(column);
        for (batch.objectives.items) |index| for (objectives[index].columns) |column| try columns.add(column);
        columns.sort();
        const batch_columns = try result_allocator.dupe(usize, columns.items.items);
        var duration_seeds: std.ArrayList(problem.DurationSeed) = .empty;
        for (batch_columns, 0..) |column, slot| if (duration_sections[column]) |section| {
            try duration_seeds.append(temporary, .{ .slot = slot, .section = section });
        };
        for (batch.constraints.items) |index| constraints[index].slots = try slots(result_allocator, constraints[index].columns, batch_columns);
        for (batch.objectives.items) |index| objectives[index].slots = try slots(result_allocator, objectives[index].columns, batch_columns);
        batches[next_batch] = .{
            .constraints = try result_allocator.dupe(usize, batch.constraints.items),
            .objectives = try result_allocator.dupe(usize, batch.objectives.items),
            .columns = batch_columns,
            .points = try result_allocator.dupe(usize, batch.points.items),
            .durations = try result_allocator.dupe(problem.DurationSeed, duration_seeds.items),
        };
        max_batch_points = @max(max_batch_points, batch.points.items.len);
        next_batch += 1;
    }
    const requirements = try result_allocator.alloc(kernel.Requirements, compiler.quantities.items.len);
    for (compiler.quantities.items, requirements) |set, *out| {
        const values = try temporary.alloc(model.Quantity, set.count());
        var iterator = set.iterator();
        var index: usize = 0;
        while (iterator.next()) |quantity| : (index += 1) values[index] = quantity;
        out.* = .init(values, false);
    }
    const curves = try result_allocator.alloc(problem.Curve, compiler.curves.items.len);
    for (compiler.curves.items, curves) |curve, *out| out.* = .{ .rule = curve.rule, .samples = try result_allocator.dupe(CurveSample, curve.samples) };
    return .{
        .x = x,
        .layout = .{
            .rules = prepared_rules,
            .mesh = built.mesh,
            .lower = lower,
            .upper = upper,
            .locations = try result_allocator.dupe(problem.Location, compiler.locations.items),
            .requirements = requirements,
            .constraints = constraints,
            .objectives = objectives,
            .curves = curves,
            .batches = batches,
            .row_offsets = row_offsets,
            .columns = constraint_columns,
            .equality_count = equality_count,
            .max_batch_points = max_batch_points,
        },
    };
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    rules: *const rules.Prepared,
    mesh: *const mesh_module.Mesh,
    base_variables: usize,
    curve_indices: []?usize,
    variables: std.ArrayList(Bounds) = .empty,
    locations: std.ArrayList(problem.Location) = .empty,
    location_indices: std.AutoHashMapUnmanaged(LocationKey, usize) = .empty,
    quantities: std.ArrayList(QuantitySet) = .empty,
    samplings: std.ArrayList(Sampling) = .empty,
    curves: std.ArrayList(problem.Curve) = .empty,
    constraints: std.ArrayList(problem.Term) = .empty,
    objectives: std.ArrayList(problem.Term) = .empty,

    fn point(self: *Compiler, location: problem.Location) std.mem.Allocator.Error!usize {
        const key: LocationKey = switch (location) {
            .cell => |cell| .{ .kind = .cell, .index = cell.index, .value = bits(cell.u) },
            .event => |event| .{ .kind = .event, .index = event.index, .value = @intFromEnum(event.side) },
            .time => |time| .{ .kind = .time, .index = 0, .value = bits(time) },
        };
        const entry = try self.location_indices.getOrPut(self.allocator, key);
        if (entry.found_existing) return entry.value_ptr.*;
        const index = self.locations.items.len;
        entry.value_ptr.* = index;
        try self.locations.append(self.allocator, location);
        try self.quantities.append(self.allocator, .initEmpty());
        return index;
    }

    fn samples(self: *Compiler, scope: model.Scope) std.mem.Allocator.Error![]const usize {
        for (self.samplings.items) |sampling| if (std.meta.eql(sampling.scope, scope)) return sampling.points;
        var points: std.ArrayList(usize) = .empty;
        switch (scope) {
            .event => |event| try points.append(self.allocator, try self.point(.{ .event = event })),
            .time => |time| try points.append(self.allocator, try self.point(.{ .time = time })),
            .time_range => |range| {
                const count = @max(subdivisions, self.mesh.cells.len * subdivisions);
                for (0..count + 1) |index| {
                    const fraction = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count));
                    try points.append(self.allocator, try self.point(.{ .time = range[0] + (range[1] - range[0]) * fraction }));
                }
            },
            else => {
                const sections: [2]usize = switch (scope) {
                    .section => |section| .{ section, section + 1 },
                    .between => |events| events,
                    .all => .{ 0, self.mesh.sections.len },
                    else => unreachable,
                };
                const first = self.mesh.sections[sections[0]].first_cell;
                const end = self.mesh.sections[sections[1] - 1].end_cell;
                for (first..end) |cell| for (0..subdivisions + 1) |index| {
                    try points.append(self.allocator, try self.point(.{ .cell = .{ .index = cell, .u = @as(f64, @floatFromInt(index)) / subdivisions } }));
                };
            },
        }
        try self.samplings.append(self.allocator, .{ .scope = scope, .points = points.items });
        return points.items;
    }

    fn check(self: *Compiler, descriptor: rules.Check, index: usize) std.mem.Allocator.Error!void {
        const points = try self.samples(descriptor.scope);
        const objective = self.rules.isObjective(descriptor);
        const duration = descriptor.operation == .quantity and self.rules.plan.rules[descriptor.operation.quantity.rule].definition.quantity.quantity == .duration;
        const sequence = if (descriptor.operation == .curve) try self.curve(descriptor.operation.curve.rule, points) else null;
        for (points, 0..) |point_index, sample| {
            if (duration and sample > 0) break;
            const term: problem.Term = .{
                .operation = if (sequence) |curve_index| .{ .curve = .{ .check = index, .variable = self.curves.items[curve_index].samples[sample].variable } } else .{ .check = index },
                .point = point_index,
                .equality = descriptor.equality,
                .weight = descriptor.weight * (if (duration) @as(f64, 1) else quadrature(self.locations.items[point_index], sample, points.len)),
            };
            if (objective) try self.objectives.append(self.allocator, term) else try self.constraints.append(self.allocator, term);
            self.checkQuantities(point_index, descriptor);
        }
    }

    fn curve(self: *Compiler, rule_index: usize, points: []const usize) std.mem.Allocator.Error!usize {
        if (self.curve_indices[rule_index]) |index| return index;
        const index = self.curves.items.len;
        const relation = self.rules.plan.rules[rule_index].definition.relation.value.follow_curve;
        const curve_samples = try self.allocator.alloc(CurveSample, points.len);
        for (points, curve_samples, 0..) |point_index, *sample, offset| {
            const variable = self.base_variables + self.variables.items.len;
            const fraction = if (points.len <= 1) 0 else @as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(points.len - 1));
            const value = relation.from + (relation.to - relation.from) * fraction;
            const endpoint = offset == 0 or offset + 1 == points.len;
            try self.variables.append(self.allocator, .{
                .value = value,
                .lower = if (endpoint) value else @min(relation.from, relation.to),
                .upper = if (endpoint) value else @max(relation.from, relation.to),
            });
            sample.* = .{ .point = point_index, .variable = variable };
            if (offset > 0) try self.constraints.append(self.allocator, .{
                .operation = .{ .progress = .{ .from = curve_samples[offset - 1].variable, .to = variable, .sign = if (relation.to >= relation.from) 1 else -1 } },
                .point = point_index,
                .equality = sameBoundary(self.locations.items[points[offset - 1]], self.locations.items[point_index]),
            });
        }
        self.curve_indices[rule_index] = index;
        try self.curves.append(self.allocator, .{ .rule = rule_index, .samples = curve_samples });
        return index;
    }

    fn quantity(self: *Compiler, point_index: usize, value: model.Quantity) void {
        if (value != .time and value != .duration) self.quantities.items[point_index].insert(value);
    }

    fn checkQuantities(self: *Compiler, point_index: usize, descriptor: rules.Check) void {
        switch (descriptor.operation) {
            .alignment => self.quantity(point_index, .horizontal_speed),
            .quantity => |operation| {
                const rule = self.rules.plan.rules[operation.rule];
                const value = rule.definition.quantity.quantity;
                if (operation.zero_norm) {
                    switch (value) {
                        .speed3d => self.quantity(point_index, .velocity_ecef),
                        .acceleration3d => self.quantity(point_index, .acceleration_ecef),
                        .horizontal_speed => self.quantity(point_index, .horizontal_speed),
                        .jerk3d => self.quantity(point_index, .jerk3d),
                        else => unreachable,
                    }
                    return;
                }
                if (value == .turn_radius and operation.comparison == .eq) {
                    self.quantity(point_index, .forward_speed);
                    self.quantity(point_index, .turn_rate);
                } else self.quantity(point_index, value);
                if (rules.rightHand(rule, operation.comparison)) |rhs| if (rhs == .event) {
                    self.quantity(problem.Layout.eventPoint(.{ .index = rhs.event.event, .side = rhs.event.side }), rhs.event.quantity);
                };
            },
            .jump => |jump| {
                self.quantity(problem.Layout.eventPoint(.{ .index = jump.event, .side = .in }), jump.quantity);
                self.quantity(problem.Layout.eventPoint(.{ .index = jump.event, .side = .out }), jump.quantity);
            },
            .curve, .region => self.quantity(point_index, .position),
            .coverage, .maximum_duration => {},
        }
    }

    fn batchPoints(self: *Compiler, batch: *Batch, term: problem.Term) std.mem.Allocator.Error!void {
        try appendPoint(self.allocator, &batch.points, term.point);
        const index = term.check() orelse return;
        switch (self.rules.checks[index].operation) {
            .quantity => |operation| {
                if (operation.zero_norm) return;
                if (rules.rightHand(self.rules.plan.rules[operation.rule], operation.comparison)) |rhs| if (rhs == .event) {
                    try appendPoint(self.allocator, &batch.points, problem.Layout.eventPoint(.{ .index = rhs.event.event, .side = rhs.event.side }));
                };
            },
            .jump => |jump| {
                try appendPoint(self.allocator, &batch.points, problem.Layout.eventPoint(.{ .index = jump.event, .side = .in }));
                try appendPoint(self.allocator, &batch.points, problem.Layout.eventPoint(.{ .index = jump.event, .side = .out }));
            },
            else => {},
        }
    }
};

const Columns = struct {
    allocator: std.mem.Allocator,
    marks: []usize,
    lower: []const f64,
    upper: []const f64,
    mesh: *const mesh_module.Mesh,
    generation: usize = 0,
    items: std.ArrayList(usize) = .empty,

    fn reset(self: *Columns) void {
        self.generation += 1;
        self.items.clearRetainingCapacity();
    }

    fn add(self: *Columns, column: usize) std.mem.Allocator.Error!void {
        if (self.lower[column] == self.upper[column] or self.marks[column] == self.generation) return;
        self.marks[column] = self.generation;
        try self.items.append(self.allocator, column);
    }

    fn sort(self: *Columns) void {
        std.mem.sort(usize, self.items.items, {}, std.sort.asc(usize));
    }

    fn durations(self: *Columns, start: usize, end: usize) std.mem.Allocator.Error!void {
        for (self.mesh.durations[start..end]) |column| try self.add(column);
    }

    fn scope(self: *Columns, value: model.Scope) std.mem.Allocator.Error!void {
        switch (value) {
            .section => |section| try self.add(self.mesh.durations[section]),
            .between => |events| try self.durations(events[0], events[1]),
            .all => try self.durations(0, self.mesh.durations.len),
            .event, .time, .time_range => {},
        }
    }

    fn physical(self: *Columns, location: problem.Location) std.mem.Allocator.Error!void {
        if (location == .time) {
            for (self.mesh.nodes) |node| for (node.variables) |column| try self.add(column);
            try self.durations(0, self.mesh.durations.len);
            return;
        }
        const cell = self.mesh.cells[cellIndex(self.mesh, location)];
        for (self.mesh.nodes[cell.left].variables) |column| try self.add(column);
        for (self.mesh.nodes[cell.right].variables) |column| try self.add(column);
        try self.add(self.mesh.durations[cell.section]);
    }

    fn quantity(self: *Columns, location: problem.Location, value: model.Quantity, quantity_scope: model.Scope) std.mem.Allocator.Error!void {
        switch (value) {
            .time => switch (location) {
                .event => |event| try self.durations(0, event.index),
                .cell => |cell| try self.durations(0, self.mesh.cells[cell.index].section + 1),
                .time => {},
            },
            .duration => try self.scope(quantity_scope),
            else => try self.physical(location),
        }
    }

    fn term(self: *Columns, compiler: *const Compiler, value: problem.Term, objective: bool) std.mem.Allocator.Error!void {
        self.reset();
        const location = compiler.locations.items[value.point];
        if (value.operation == .progress) {
            try self.add(value.operation.progress.from);
            try self.add(value.operation.progress.to);
        } else {
            const descriptor = compiler.rules.checks[value.check().?];
            switch (descriptor.operation) {
                .alignment, .region => try self.physical(location),
                .curve => {
                    try self.physical(location);
                    try self.add(value.operation.curve.variable);
                },
                .coverage, .maximum_duration => try self.durations(0, self.mesh.durations.len),
                .jump => |jump| {
                    const incoming: model.EventRef = .{ .index = jump.event, .side = .in };
                    const outgoing: model.EventRef = .{ .index = jump.event, .side = .out };
                    try self.quantity(.{ .event = incoming }, jump.quantity, .{ .event = incoming });
                    try self.quantity(.{ .event = outgoing }, jump.quantity, .{ .event = outgoing });
                    if (jump.range != null) try self.durations(0, jump.event);
                },
                .quantity => |operation| {
                    const rule = compiler.rules.plan.rules[operation.rule];
                    try self.quantity(location, rule.definition.quantity.quantity, descriptor.scope);
                    if (!operation.zero_norm) {
                        if (rules.rightHand(rule, operation.comparison)) |rhs| if (rhs == .event) {
                            const event: model.EventRef = .{ .index = rhs.event.event, .side = rhs.event.side };
                            try self.quantity(.{ .event = event }, rhs.event.quantity, .{ .event = event });
                        };
                    }
                },
            }
            if (objective) if (descriptor.average_scope) |average_scope| {
                try self.scope(average_scope);
                if (location == .cell) try self.add(self.mesh.durations[self.mesh.cells[location.cell.index].section]);
            };
        }
        self.sort();
    }
};

fn slots(allocator: std.mem.Allocator, term_columns: []const usize, batch_columns: []const usize) std.mem.Allocator.Error![]const usize {
    const result = try allocator.alloc(usize, term_columns.len);
    var slot: usize = 0;
    for (term_columns, result) |column, *out| {
        while (batch_columns[slot] != column) slot += 1;
        out.* = slot;
    }
    return result;
}

fn appendPoint(allocator: std.mem.Allocator, points: *std.ArrayList(usize), point: usize) std.mem.Allocator.Error!void {
    for (points.items) |existing| if (existing == point) return;
    try points.append(allocator, point);
}

fn cellIndex(mesh: *const mesh_module.Mesh, location: problem.Location) usize {
    return switch (location) {
        .cell => |cell| cell.index,
        .event => |event| if (event.index == 0)
            0
        else if (event.side == .out and event.index < mesh.sections.len)
            mesh.sections[event.index].first_cell
        else
            mesh.sections[event.index - 1].end_cell - 1,
        .time => unreachable,
    };
}

fn quadrature(location: problem.Location, sample: usize, count: usize) f64 {
    const index = if (location == .cell) @as(usize, @intFromFloat(@round(location.cell.u * subdivisions))) else sample;
    const last = if (location == .cell) subdivisions else count - 1;
    if (last == 0 or location == .event) return 1;
    const weight: f64 = if (index == 0 or index == last) 1 else if (index % 2 == 1) 4 else 2;
    return weight / @as(f64, @floatFromInt(3 * last));
}

fn sameBoundary(a: problem.Location, b: problem.Location) bool {
    return a == .cell and b == .cell and a.cell.index + 1 == b.cell.index and a.cell.u == 1 and b.cell.u == 0;
}

fn bits(value: f64) u64 {
    return @bitCast(if (value == 0) @as(f64, 0) else value);
}
