const std = @import("std");
const shared = @import("shared");
const gnss = shared.gnss;
const bundle = shared.bundle;
const types = shared.core.types;
const NavSet = bundle.navigation.NavSet;
const Binding = bundle.plan.Binding;
const Row = gnss.air.Row;

pub fn air(set: *const NavSet, binding: *const Binding, carried: *const gnss.payload.Carried, signal: types.Signal) Row {
    const family = carried.get(signal);
    switch (binding.reference) {
        .kepler => {
            const reference = binding.kepler(set).?;
            // A signal the satellite does not transmit is read with the family its signal names.
            const health = reference.attributesFor(family orelse gnss.spec.get(signal).family).signalStatus(signal);
            const status: gnss.air.Status = if (!health.flies()) .dead else if (family == null) .not_allocated else .on_air;
            // The B2b that carries PPP-B2b has no group delay of its own: it flies at B3I's, the BDS clock reference.
            if (signal == .b2b and gnss.payload.pppB2b(reference.record.sat, carried)) return .{ .status = status, .health = health, .delay_s = .initFill(0), .origin = .convention };
            const data = reference.delay(signal, .data);
            return .{
                .status = status,
                .health = health,
                .delay_s = .init(.{ .data = data orelse 0, .pilot = reference.delay(signal, .pilot) orelse 0 }),
                .origin = origin(signal, data),
            };
        },
        .glonass => |i| {
            const delay = gnss.delay.forGlonass(&binding.group_delay, signal);
            return .{
                .status = if (family == null) .not_allocated else .on_air,
                .health = gnss.health.flagged(!set.glonass[i].health),
                .delay_s = .initFill(delay orelse 0),
                .origin = origin(signal, delay),
            };
        },
    }
}

fn origin(signal: types.Signal, delay: ?f64) gnss.air.Origin {
    if (delay == null) return .assumed;
    return if (gnss.delay.convention(signal)) .convention else .broadcast;
}

pub fn rows(arena: std.mem.Allocator, set: *const NavSet, sat: types.SatId, binding: *const Binding, carried: *const gnss.payload.Carried) std.mem.Allocator.Error![]const Row {
    const out = try arena.alloc(Row, gnss.spec.signalCount(sat.system));
    for (std.meta.tags(types.Signal)) |signal| {
        if (signal.system() == sat.system) out[gnss.spec.slot(signal)] = air(set, binding, carried, signal);
    }
    return out;
}
