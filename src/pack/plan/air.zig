const std = @import("std");
const shared = @import("shared");
const gnss = shared.gnss;
const bundle = shared.bundle;
const types = shared.core.types;
const NavSet = bundle.navigation.NavSet;
const Binding = bundle.plan.Binding;
const Row = gnss.air.Row;

pub fn air(set: *const NavSet, binding: *const Binding, allocated: std.EnumSet(types.Signal), signal: types.Signal) Row {
    switch (binding.reference) {
        .kepler => {
            const reference = binding.kepler(set).?;
            const data = reference.delay(signal, .data);
            const health = reference.attributesFor(signal).signalStatus(signal);
            return .{
                .status = if (!health.flies()) .dead else if (!allocated.contains(signal)) .not_allocated else .on_air,
                .health = health,
                .delay_s = .init(.{ .data = data orelse 0, .pilot = reference.delay(signal, .pilot) orelse 0 }),
                .origin = origin(reference.record.sat, signal, data),
            };
        },
        .glonass => |i| {
            const g = &set.glonass[i];
            const delay = gnss.delay.forGlonass(g, signal);
            return .{
                .status = if (!allocated.contains(signal)) .not_allocated else .on_air,
                .health = gnss.health.flagged(!g.health),
                .delay_s = .initFill(delay orelse 0),
                .origin = origin(g.sat, signal, delay),
            };
        },
    }
}

fn origin(sat: types.SatId, signal: types.Signal, delay: ?f64) gnss.air.Origin {
    if (delay == null) return .assumed;
    return if (gnss.delay.convention(sat.prn(), signal)) .convention else .broadcast;
}

pub fn rows(arena: std.mem.Allocator, set: *const NavSet, sat: types.SatId, binding: *const Binding, allocated: std.EnumSet(types.Signal)) std.mem.Allocator.Error![]const Row {
    const out = try arena.alloc(Row, gnss.spec.signalCount(sat.system));
    for (std.meta.tags(types.Signal)) |signal| {
        if (signal.system() == sat.system) out[gnss.spec.slot(signal)] = air(set, binding, allocated, signal);
    }
    return out;
}
