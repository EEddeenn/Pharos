const model = @import("../plan.zig").model;
const rules = @import("rules.zig");
const mesh = @import("mesh.zig");
const kernel = @import("kernel.zig");
const nlp = @import("nlp.zig");

pub const prepare = @import("problem/prepare.zig").prepare;
pub const Workspace = @import("problem/evaluate.zig").Workspace;

pub const Location = union(enum) {
    cell: struct { index: usize, u: f64 },
    event: model.EventRef,
    time: f64,
    /// Not a point of the path: control point `k` of the `order`-th derivative of a cell's place over the part
    /// `low` to `high` of the cell. The derivative lies within its control points over that part, so a row that
    /// is linear in it, or a bound on its norm, holds over the part where it holds at each of them.
    control: struct { index: usize, low: f64, high: f64, order: u8, k: u8 },
};

pub const Term = struct {
    operation: union(enum) {
        check: usize,
        curve: struct { check: usize, variable: usize },
        progress: struct { from: usize, to: usize, sign: f64 },
    },
    point: usize,
    equality: bool,
    weight: f64 = 1,
    margin: f64 = 0,
    columns: []const usize = &.{},
    slots: []const usize = &.{},

    pub fn check(self: Term) ?usize {
        return switch (self.operation) {
            .check => |index| index,
            .curve => |curve| curve.check,
            .progress => null,
        };
    }
};

pub const Curve = struct {
    rule: usize,
    samples: []const struct { point: usize, variable: usize },
};

pub const Batch = struct {
    constraints: []const usize,
    objectives: []const usize,
    columns: []const usize,
    points: []const usize,
    durations: []const DurationSeed,
};

pub const DurationSeed = struct { slot: usize, section: usize };

pub const Layout = struct {
    rules: *const rules.Prepared,
    mesh: mesh.Mesh,
    lower: []const f64,
    upper: []const f64,
    locations: []const Location,
    requirements: []const kernel.Requirements,
    constraints: []const Term,
    objectives: []const Term,
    curves: []const Curve,
    batches: []const Batch,
    row_offsets: []const usize,
    columns: []const usize,
    soft_offsets: []const usize,
    soft_columns: []const usize,
    curved_offsets: []const usize,
    order: []const usize,
    equality_count: usize,
    max_batch_points: usize,

    pub fn numerical(self: *const Layout) nlp.Layout {
        return .{
            .constraint_count = self.constraints.len,
            .equality_count = self.equality_count,
            .row_offsets = self.row_offsets,
            .columns = self.columns,
            .soft_offsets = self.soft_offsets,
            .soft_columns = self.soft_columns,
            .curved_offsets = self.curved_offsets,
            .order = self.order,
            .lower = self.lower,
            .upper = self.upper,
        };
    }

    pub fn eventPoint(event: model.EventRef) usize {
        return event.index * 2 + @intFromBool(event.side == .out);
    }
};

pub const Prepared = struct {
    layout: Layout,
    x: []f64,
};
