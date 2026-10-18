const std = @import("std");
const model = @import("../../plan.zig").model;
const problem = @import("../problem.zig");
const mesh_module = @import("../mesh.zig");
const kernel = @import("../kernel.zig");
const rules = @import("../rules.zig");
const nlp = @import("../nlp.zig");
const candidate = @import("../candidate.zig");
const Scalar = kernel.Scalar;
const Differential = kernel.Differential;
const Dual = kernel.Dual;
const unseeded = std.math.maxInt(u8);
const no_slot = std.math.maxInt(usize);

const Place = struct { cell: usize, u: f64 };

pub const Workspace = struct {
    layout: *const problem.Layout,
    times: []f64,
    places: []Place,
    scalar_points: []Scalar.Point,
    scalar_ready: []bool,
    scalar_cells: []Scalar.Cell,
    scalar_cell_ready: []bool,
    derivative_points: []Differential.Point,
    derivative_ready: []bool,
    derivative_cells: []Differential.Cell,
    derivative_cell_ready: []bool,
    point_slots: []usize,
    cell_slots: []usize,
    active_cells: []usize,
    seeds: []u8,
    time_only: []bool,
    relevant: []bool,

    pub fn init(allocator: std.mem.Allocator, layout: *const problem.Layout) std.mem.Allocator.Error!Workspace {
        const seeds = try allocator.alloc(u8, layout.lower.len);
        @memset(seeds, unseeded);
        const cell_slots = try allocator.alloc(usize, layout.mesh.cells.len);
        @memset(cell_slots, no_slot);
        const relevant = try allocator.alloc(bool, layout.lower.len);
        @memset(relevant, false);
        const time_only = try allocator.alloc(bool, layout.batches.len);
        for (time_only, layout.batches) |*flag, batch| flag.* = timeOnly(layout, batch);
        return .{
            .layout = layout,
            .times = try allocator.alloc(f64, layout.mesh.durations.len + 1),
            .places = try allocator.alloc(Place, layout.locations.len),
            .scalar_points = try allocator.alloc(Scalar.Point, layout.locations.len),
            .scalar_ready = try allocator.alloc(bool, layout.locations.len),
            .scalar_cells = try allocator.alloc(Scalar.Cell, layout.mesh.cells.len),
            .scalar_cell_ready = try allocator.alloc(bool, layout.mesh.cells.len),
            .derivative_points = try allocator.alloc(Differential.Point, layout.max_batch_points),
            .derivative_ready = try allocator.alloc(bool, layout.max_batch_points),
            .derivative_cells = try allocator.alloc(Differential.Cell, layout.max_batch_points),
            .derivative_cell_ready = try allocator.alloc(bool, layout.max_batch_points),
            .point_slots = try allocator.alloc(usize, layout.locations.len),
            .cell_slots = cell_slots,
            .active_cells = try allocator.alloc(usize, layout.max_batch_points),
            .seeds = seeds,
            .time_only = time_only,
            .relevant = relevant,
        };
    }

    fn reset(self: *Workspace, x: []const f64) void {
        self.times[0] = 0;
        for (self.layout.mesh.durations, 0..) |column, i| self.times[i + 1] = self.times[i] + x[column] * mesh_module.time_scale;
        for (self.layout.locations, self.places) |location, *place| place.* = switch (location) {
            .cell => |cell| .{ .cell = cell.index, .u = cell.u },
            .event => |event| blk: {
                if (event.index == 0 or (event.side == .out and event.index < self.layout.mesh.sections.len)) break :blk .{ .cell = self.layout.mesh.sections[event.index].first_cell, .u = 0 };
                break :blk .{ .cell = self.layout.mesh.sections[event.index - 1].end_cell - 1, .u = 1 };
            },
            .time => |time| blk: {
                var low: usize = 0;
                var high = self.layout.mesh.cells.len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const cell = self.layout.mesh.cells[middle];
                    const end = self.times[cell.section] + x[self.layout.mesh.durations[cell.section]] * mesh_module.time_scale * cell.end;
                    if (time <= end) high = middle else low = middle + 1;
                }
                const index = @min(low, self.layout.mesh.cells.len - 1);
                const cell = self.layout.mesh.cells[index];
                const span = x[self.layout.mesh.durations[cell.section]] * mesh_module.time_scale;
                break :blk .{ .cell = index, .u = (time - self.times[cell.section] - span * cell.start) / (span * (cell.end - cell.start)) };
            },
        };
        @memset(self.scalar_ready, false);
        @memset(self.scalar_cell_ready, false);
    }

    pub fn values(self: *Workspace, x: []const f64, out: nlp.Values) nlp.EvalError!void {
        self.reset(x);
        var context: Context(Scalar) = .{ .workspace = self, .x = x, .points = self.scalar_points, .ready = self.scalar_ready, .cells = self.scalar_cells, .cell_ready = self.scalar_cell_ready };
        for (self.layout.constraints, 0..) |term, row| {
            const result = residual(Scalar, &context, term);
            if (!std.math.isFinite(result)) return error.Domain;
            out.constraints[row] = result;
        }
        out.objective.* = 0;
        for (self.layout.objectives) |term| {
            const result = objective(Scalar, &context, term).value;
            if (!std.math.isFinite(result)) return error.Domain;
            out.objective.* += result;
        }
        if (!std.math.isFinite(out.objective.*)) return error.Domain;
    }

    pub fn derivatives(self: *Workspace, x: []const f64, out: nlp.Derivatives) nlp.EvalError!void {
        self.reset(x);
        @memset(out.gradient, 0);
        @memset(out.soft, 0);
        @memset(out.curved, 0);
        var context: Context(Differential) = .{ .workspace = self, .x = x, .points = self.derivative_points, .ready = self.derivative_ready, .cells = self.derivative_cells, .cell_ready = self.derivative_cell_ready };
        for (self.layout.batches, self.time_only) |batch, time_only| {
            if (batch.columns.len == 0) continue;
            const located = self.layout.mesh.cells[self.places[batch.points[0]].cell];
            if (time_only) self.mark(located, true);
            defer if (time_only) self.mark(located, false);
            var cell_count: usize = 0;
            for (batch.points, 0..) |point, slot| {
                self.point_slots[point] = slot;
                const cell = self.places[point].cell;
                if (self.cell_slots[cell] == no_slot) {
                    self.cell_slots[cell] = cell_count;
                    self.active_cells[cell_count] = cell;
                    cell_count += 1;
                }
            }
            defer for (self.active_cells[0..cell_count]) |cell| {
                self.cell_slots[cell] = no_slot;
            };
            var offset: usize = 0;
            var duration_offset: usize = 0;
            while (offset < batch.columns.len) : (offset += Dual.lanes) {
                const active = batch.columns[offset..@min(offset + Dual.lanes, batch.columns.len)];
                if (time_only) {
                    var any = false;
                    for (active) |column| any = any or self.relevant[column];
                    if (!any) {
                        for (batch.constraints) |row| {
                            for (self.layout.constraints[row].slots, 0..) |slot, i| {
                                if (slot >= offset and slot < offset + active.len) out.jacobian[self.layout.row_offsets[row] + i] = 0;
                            }
                        }
                        while (duration_offset < batch.durations.len and batch.durations[duration_offset].slot < offset + active.len) duration_offset += 1;
                        continue;
                    }
                }
                for (active, 0..) |column, slot| self.seeds[column] = @intCast(slot);
                defer for (active) |column| {
                    self.seeds[column] = unseeded;
                };
                const duration_start = duration_offset;
                while (duration_offset < batch.durations.len and batch.durations[duration_offset].slot < offset + active.len) duration_offset += 1;
                context.duration_seeds = batch.durations[duration_start..duration_offset];
                context.seed_offset = offset;
                @memset(self.derivative_ready[0..batch.points.len], false);
                @memset(self.derivative_cell_ready[0..cell_count], false);
                for (batch.constraints) |row| {
                    const term = self.layout.constraints[row];
                    const result = residual(Differential, &context, term);
                    if (!result.isFinite()) return error.Domain;
                    for (term.slots, 0..) |slot, i| {
                        if (slot >= offset and slot < offset + active.len) out.jacobian[self.layout.row_offsets[row] + i] = result.derivatives[slot - offset];
                    }
                    const group = out.curved[self.layout.curved_offsets[row]..self.layout.curved_offsets[row + 1]];
                    if (group.len == 0) continue;
                    const check = self.layout.rules.checks[term.check().?];
                    const root = @sqrt(rules.bend(self.layout.rules, check).factor);
                    const vector = rules.bent(Differential, self.layout.rules, check, Sampler(Differential){ .context = &context, .term = term });
                    for (0..group.len / term.slots.len) |k| for (term.slots, group[k * term.slots.len ..][0..term.slots.len]) |slot, *entry| {
                        if (slot >= offset and slot < offset + active.len) entry.* = root * vector[k].derivatives[slot - offset];
                    };
                }
                for (batch.objectives) |index| {
                    const term = self.layout.objectives[index];
                    const result = objective(Differential, &context, term);
                    if (!result.value.isFinite()) return error.Domain;
                    const root = @sqrt(result.curvature);
                    for (term.columns, term.slots, self.layout.soft_offsets[index]..) |column, slot, entry| {
                        if (slot < offset or slot >= offset + active.len) continue;
                        out.gradient[column] += result.value.derivatives[slot - offset];
                        out.soft[entry] = root * result.residual.derivatives[slot - offset];
                    }
                }
            }
        }
    }

    /// The columns the state at a fixed time depends on, at the current variables: the two nodes of its cell
    /// and the durations up to its section.
    fn mark(self: *Workspace, cell: mesh_module.Cell, value: bool) void {
        const mesh = self.layout.mesh;
        for (mesh.nodes[cell.left].variables) |column| self.relevant[column] = value;
        for (mesh.nodes[cell.right].variables) |column| self.relevant[column] = value;
        for (mesh.durations[0 .. cell.section + 1]) |column| self.relevant[column] = value;
    }

    pub fn candidateOf(self: *Workspace, allocator: std.mem.Allocator, x: []const f64) std.mem.Allocator.Error!candidate.Candidate {
        self.reset(x);
        var context: Context(Scalar) = .{ .workspace = self, .x = x, .points = self.scalar_points, .ready = self.scalar_ready, .cells = self.scalar_cells, .cell_ready = self.scalar_cell_ready };
        const nodes = try allocator.alloc(Scalar.Jet, self.layout.mesh.nodes.len);
        for (nodes, 0..) |*node, index| {
            node.* = context.jet(index);
            for (&node.position, self.layout.mesh.origin.toArray()) |*position, origin| position.* += origin;
        }
        const durations = try allocator.alloc(f64, self.layout.mesh.durations.len);
        for (durations, 0..) |*duration, section| duration.* = context.duration(section);
        const prepared = self.layout.rules;
        const path = try candidate.Path.init(allocator, prepared.plan.name, prepared.plan.coordinates.altitude, nodes, self.layout.mesh.cells, durations);
        const curves = try allocator.alloc(candidate.CurveProgress, self.layout.curves.len);
        for (curves, self.layout.curves) |*curve, source| {
            const samples = try allocator.alloc(candidate.Progress, source.samples.len);
            for (samples, source.samples) |*sample, from| sample.* = .{ .time = context.timeAt(from.point), .value = x[from.variable] };
            curve.* = .{ .rule = source.rule, .samples = samples };
        }
        return .{ .path = path, .curves = curves };
    }
};

/// Whether a batch is one point at a fixed time whose terms depend on the state there alone.
fn timeOnly(layout: *const problem.Layout, batch: problem.Batch) bool {
    if (batch.points.len != 1 or layout.locations[batch.points[0]] != .time) return false;
    for ([_][]const usize{ batch.constraints, batch.objectives }, [_][]const problem.Term{ layout.constraints, layout.objectives }) |indices, terms| for (indices) |index| {
        const check = layout.rules.checks[terms[index].check() orelse return false];
        switch (check.operation) {
            .region => {},
            .quantity => |operation| {
                const rule = layout.rules.plan.rules[operation.rule];
                const quantity = rule.definition.quantity.quantity;
                if (quantity == .time or quantity == .duration) return false;
                if (!operation.split_norm) if (rules.rightHand(rule, operation.comparison)) |rhs| if (rhs == .event) return false;
            },
            else => return false,
        }
    };
    return true;
}

fn Context(comptime K: type) type {
    const N = K.Number;
    const A = K.Arithmetic;
    return struct {
        workspace: *Workspace,
        x: []const f64,
        duration_seeds: []const problem.DurationSeed = &.{},
        seed_offset: usize = 0,
        points: []K.Point,
        ready: []bool,
        cells: []K.Cell,
        cell_ready: []bool,

        const Self = @This();

        fn variable(self: *const Self, index: usize) N {
            if (N == f64) return self.x[index];
            const lane = self.workspace.seeds[index];
            return if (lane == unseeded) Dual.constant(self.x[index]) else Dual.variable(self.x[index], lane);
        }

        fn duration(self: *const Self, section: usize) N {
            return A.scale(self.variable(self.workspace.layout.mesh.durations[section]), mesh_module.time_scale);
        }

        fn eventTime(self: *const Self, event: usize) N {
            var result = A.constant(self.workspace.times[event]);
            if (N != f64) for (self.duration_seeds) |seed| {
                if (seed.section < event) result.derivatives[seed.slot - self.seed_offset] = mesh_module.time_scale;
            };
            return result;
        }

        fn jet(self: *const Self, node: usize) K.Jet {
            const mesh = self.workspace.layout.mesh;
            const indices = mesh.nodes[node].variables;
            var result: K.Jet = undefined;
            for (0..3) |axis| {
                result.position[axis] = A.scale(self.variable(indices[axis]), mesh.scales[axis]);
                result.velocity[axis] = A.scale(self.variable(indices[axis + 3]), mesh.scales[axis + 3]);
                result.acceleration[axis] = A.scale(self.variable(indices[axis + 6]), mesh.scales[axis + 6]);
            }
            return result;
        }

        fn cell(self: *Self, index: usize) *const K.Cell {
            const slot = if (N == f64) index else self.workspace.cell_slots[index];
            if (!self.cell_ready[slot]) {
                const piece = self.workspace.layout.mesh.cells[index];
                self.cells[slot] = K.Cell.init(self.jet(piece.left), self.jet(piece.right), A.scale(self.duration(piece.section), piece.end - piece.start));
                self.cell_ready[slot] = true;
            }
            return &self.cells[slot];
        }

        fn point(self: *Self, index: usize) *K.Point {
            const slot = if (N == f64) index else self.workspace.point_slots[index];
            if (!self.ready[slot]) {
                const layout = self.workspace.layout;
                const place = self.workspace.places[index];
                const piece = layout.mesh.cells[place.cell];
                const span = self.duration(piece.section);
                const u = switch (layout.locations[index]) {
                    .time => |time| A.div(A.sub(A.sub(A.constant(time), self.eventTime(piece.section)), A.scale(span, piece.start)), A.scale(span, piece.end - piece.start)),
                    else => A.constant(place.u),
                };
                var state = self.cell(place.cell).at(u);
                for (&state.position, layout.mesh.origin.toArray()) |*position, origin| position.* = A.add(position.*, A.constant(origin));
                self.points[slot] = K.Point.init(state, layout.rules.plan.coordinates.altitude);
                self.points[slot].prepareRequirements(layout.requirements[index]);
                self.ready[slot] = true;
            }
            return &self.points[slot];
        }

        fn timeAt(self: *const Self, index: usize) N {
            return switch (self.workspace.layout.locations[index]) {
                .time => |time| A.constant(time),
                .event => |event| self.eventTime(event.index),
                .cell => |place| blk: {
                    const piece = self.workspace.layout.mesh.cells[place.index];
                    break :blk A.add(self.eventTime(piece.section), A.scale(self.duration(piece.section), piece.start + place.u * (piece.end - piece.start)));
                },
            };
        }

        fn scopeDuration(self: *const Self, scope: model.Scope) N {
            return switch (scope) {
                .event, .time => A.constant(0),
                .section => |section| self.duration(section),
                .between => |events| A.sub(self.eventTime(events[1]), self.eventTime(events[0])),
                .time_range => |times| A.constant(times[1] - times[0]),
                .all => self.eventTime(self.workspace.layout.mesh.durations.len),
            };
        }

        fn quantity(self: *Self, index: usize, requested: model.Quantity, scope: model.Scope) K.Vector {
            return switch (requested) {
                .time => .{ self.timeAt(index), A.constant(0), A.constant(0) },
                .duration => .{ self.scopeDuration(scope), A.constant(0), A.constant(0) },
                else => self.point(index).quantity(requested),
            };
        }
    };
}

fn Sampler(comptime K: type) type {
    return struct {
        context: *Context(K),
        term: problem.Term,

        const Self = @This();

        pub fn point(self: Self) *K.Point {
            return self.context.point(self.term.point);
        }

        pub fn quantity(self: Self, requested: model.Quantity, scope: model.Scope) K.Vector {
            return self.context.quantity(self.term.point, requested, scope);
        }

        pub fn eventTime(self: Self, event: usize) K.Number {
            return self.context.eventTime(event);
        }

        pub fn eventQuantity(self: Self, event: model.EventRef, requested: model.Quantity) K.Vector {
            return self.context.quantity(problem.Layout.eventPoint(event), requested, .{ .event = event });
        }

        pub fn atRest(self: Self, event: model.EventRef) bool {
            return self.context.point(problem.Layout.eventPoint(event)).atRest();
        }

        pub fn progress(self: Self, _: usize) K.Number {
            return self.context.variable(self.term.operation.curve.variable);
        }
    };
}

fn residual(comptime K: type, context: *Context(K), term: problem.Term) K.Number {
    if (term.operation == .progress) {
        const progress = term.operation.progress;
        return K.Arithmetic.scale(K.Arithmetic.sub(context.variable(progress.to), context.variable(progress.from)), progress.sign);
    }
    const prepared = context.workspace.layout.rules;
    const value = rules.residual(K, prepared, prepared.checks[term.check().?], Sampler(K){ .context = context, .term = term }, .optimization);
    return if (term.margin == 0) value else K.Arithmetic.sub(value, K.Arithmetic.constant(term.margin));
}

/// A soft term: its value, and what its Gauss-Newton row is made of. The term is `curvature / 2` times the square
/// of `residual` where it is a weighted square (the weight taken as it stands), and `curvature` is zero elsewhere.
fn Soft(comptime K: type) type {
    return struct { value: K.Number, residual: K.Number, curvature: f64 };
}

fn objective(comptime K: type, context: *Context(K), term: problem.Term) Soft(K) {
    const A = K.Arithmetic;
    const layout = context.workspace.layout;
    const check = layout.rules.checks[term.check().?];
    const base = residual(K, context, term);
    var result = base;
    if (check.operation == .region and A.value(result) >= 0) return .{ .value = A.constant(0), .residual = base, .curvature = 0 };
    if (check.square) result = A.mul(result, result);
    var curvature: f64 = if (check.square) 2 * term.weight else 0;
    if (check.average_scope) |scope| {
        const duration_quantity = check.operation == .quantity and layout.rules.plan.rules[check.operation.quantity.rule].definition.quantity.quantity == .duration;
        const measure = if (duration_quantity) context.scopeDuration(scope) else switch (layout.locations[term.point]) {
            .cell => |place| blk: {
                const cell = layout.mesh.cells[place.index];
                break :blk A.scale(context.duration(cell.section), cell.end - cell.start);
            },
            else => context.scopeDuration(scope),
        };
        result = A.mul(result, measure);
        curvature *= A.value(measure);
        if (!check.integral) {
            const whole = context.scopeDuration(scope);
            result = A.div(result, whole);
            curvature /= A.value(whole);
        }
    }
    return .{ .value = A.scale(result, term.weight), .residual = base, .curvature = @max(0, curvature) };
}
