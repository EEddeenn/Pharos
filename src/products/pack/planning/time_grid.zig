const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const flight_plan = @import("simulation/model/flight_plan");
const GpsTime = @import("domain/time/gps").GpsTime;

pub const Error = std.mem.Allocator.Error;

pub fn samples(arena: std.mem.Allocator, start: GpsTime, span_ms: u64, system: gnss_types.System, leap: civil.Leap) Error![]const GpsTime {
    var out: std.ArrayList(GpsTime) = .empty;
    try out.append(arena, start);
    const end_ms = start.ms + @as(i64, @intCast(span_ms));
    var t = start;
    while (true) {
        const next = flight_plan.nextLegBoundary(system, t, leap);
        if (next.ms > end_ms) break;
        try out.append(arena, next);
        t = next;
    }
    return out.items;
}
