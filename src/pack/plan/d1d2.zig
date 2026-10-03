const std = @import("std");
const shared = @import("shared");
const gnss = shared.gnss;
const bundle = shared.bundle;

pub fn prepare(arena: std.mem.Allocator, scenario: *const bundle.scenario.Scenario, navigation: *const bundle.navigation.NavSet, plan: *bundle.plan.Plan) error{OutOfMemory}!void {
    if (scenario.samples == null or !scenario.carries(.d1d2)) return;
    var entries: std.ArrayList(bundle.plan.D1d2Entry) = .empty;
    for (plan.timelines) |timeline| {
        if (!gnss.allocation.transmitsFamily(timeline.sat, .d1d2, plan.start)) continue;
        for (timeline.legs, 0..) |*leg, i| {
            const binding = if (leg.binding) |*binding| binding else continue;
            const record = binding.kepler(navigation).?;
            const interval = plan.legInterval(timeline.legs, i);
            const flight: gnss.bds.d1d2.Flight = .{ .record = record, .interval = .{ .first = interval.first, .last = interval.last } };
            try entries.append(arena, .{
                .sat = timeline.sat,
                .from_ms = leg.from_ms,
                .record = binding.reference.kepler,
                .interval = flight.interval,
                .result = gnss.bds.d1d2.prepare(flight),
            });
        }
    }
    plan.d1d2 = try entries.toOwnedSlice(arena);
}
