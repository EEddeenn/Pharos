const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const nequick = @import("domain/propagation/ionosphere/nequick");
const ionosphere_config = @import("simulation/model/ionosphere");

pub const Info = struct {
    resolved: *const ionosphere_config.Resolved,
    enabled: std.EnumSet(gnss_types.System),

    pub fn of(resolved: *const ionosphere_config.Resolved, signals: std.EnumSet(gnss_types.Signal)) Info {
        var enabled: std.EnumSet(gnss_types.System) = .empty;
        var it = signals.iterator();
        while (it.next()) |signal| enabled.insert(signal.system());
        return .{ .resolved = resolved, .enabled = enabled };
    }
};

pub const ModelSet = struct {
    models: ionosphere_model.Models = .{},
    nequick_data: ?*const nequick.Data = null,

    pub fn init(gpa: std.mem.Allocator, resolved: *const ionosphere_config.Resolved) error{OutOfMemory}!ModelSet {
        var out: ModelSet = .{};
        errdefer out.deinit(gpa);
        const broadcast = resolved.broadcast;
        for (gnss_types.System.all) |system| {
            const applied = resolved.systems.get(system);
            const value: ionosphere_model.Model = switch (applied.model) {
                .none => .none,
                .klobuchar => .{ .klobuchar = broadcast.klobuchar },
                .bds_klobuchar => .{ .bds_klobuchar = broadcast.bds_klobuchar },
                .nequick => blk: {
                    if (out.nequick_data == null) out.nequick_data = try nequick.Data.create(gpa);
                    break :blk .{ .nequick = .{ .data = out.nequick_data.?, .coefficients = broadcast.nequick.? } };
                },
                .bdgim => .{ .bdgim = .{ .alpha = broadcast.bdgim.? } },
            };
            out.models.values.set(system, value);
        }
        return out;
    }

    pub fn deinit(self: *ModelSet, gpa: std.mem.Allocator) void {
        if (self.nequick_data) |data| data.destroy(gpa);
        self.* = .{};
    }
};
