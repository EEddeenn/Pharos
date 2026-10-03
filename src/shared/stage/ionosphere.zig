const std = @import("std");
const core = @import("../core.zig");
const configuration = @import("../bundle.zig").ionosphere;
const iono = core.iono;
const types = core.types;

pub const Broadcast = configuration.Broadcast;

pub const Ionosphere = struct {
    requested: configuration.Selection,
    enabled: std.EnumSet(types.System) = .empty,
    broadcast: Broadcast,
    models: iono.Models = .{},
    sources: std.EnumArray(types.System, configuration.Source) = .initFill(.none),
    nequick_data: ?*const iono.nequick.Data = null,

    pub fn create(gpa: std.mem.Allocator, resolved: *const configuration.Resolved, signals: std.EnumSet(types.Signal)) error{OutOfMemory}!Ionosphere {
        var out: Ionosphere = .{ .requested = resolved.requested, .broadcast = resolved.broadcast };
        errdefer out.deinit(gpa);
        var enabled = signals.iterator();
        while (enabled.next()) |signal| out.enabled.insert(signal.system());
        for (types.System.all) |system| {
            const applied = resolved.systems.get(system);
            const broadcast = resolved.broadcast;
            const model: iono.Model = switch (applied.model) {
                .none => .none,
                .klobuchar => .{ .klobuchar = broadcast.klobuchar },
                .bds_klobuchar => .{ .bds_klobuchar = .{ .coefficients = broadcast.bds_klobuchar } },
                .nequick => blk: {
                    if (out.nequick_data == null) out.nequick_data = try iono.nequick.Data.create(gpa);
                    break :blk .{ .nequick = .{ .data = out.nequick_data.?, .coefficients = broadcast.nequick.? } };
                },
                .bdgim => .{ .bdgim = .{ .alpha = broadcast.bdgim.? } },
            };
            out.models.values.set(system, model);
            out.sources.set(system, applied.source);
        }
        return out;
    }

    pub fn deinit(self: *Ionosphere, gpa: std.mem.Allocator) void {
        if (self.nequick_data) |data| data.destroy(gpa);
        self.nequick_data = null;
        self.models = .{};
    }
};
