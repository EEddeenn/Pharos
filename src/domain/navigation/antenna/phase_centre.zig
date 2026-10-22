const std = @import("std");
const clock_reference = @import("domain/navigation/clock_reference");
const gnss_types = @import("domain/gnss_types");
const attitude = @import("domain/earth/attitude");
const signal_catalog = @import("domain/signals/catalog");
const yaw_law = @import("domain/navigation/antenna/yaw_law");

const GpsTime = @import("domain/time/gps").GpsTime;
const Antenna = @import("domain/navigation/antenna/catalog").Antenna;

const ClockRef = clock_reference.ClockRef;
const ClockReferences = clock_reference.ClockReferences;

pub const PhaseCentre = struct {
    reference_m: [3]f64,
    offset_m: [signal_catalog.max_per_system][3]f64,
    law: attitude.Law,
};

pub const PhaseCentres = struct {
    entries: []const Entry,

    const Entry = struct {
        sat: gnss_types.SatId,
        valid_from: GpsTime,
        valid_until: ?GpsTime,
        centre: ?PhaseCentre,
    };

    pub fn init(arena: std.mem.Allocator, antennas: []const Antenna, refs: ClockReferences) std.mem.Allocator.Error!PhaseCentres {
        const entries = try arena.alloc(Entry, antennas.len);
        for (entries, antennas) |*entry, *a| entry.* = .{
            .sat = a.sat,
            .valid_from = a.valid_from,
            .valid_until = a.valid_until,
            .centre = project(a, refs.get(a.sat.system)),
        };
        return .{ .entries = entries };
    }

    pub fn at(self: PhaseCentres, sat: gnss_types.SatId, t: GpsTime) ?PhaseCentre {
        var best: ?*const Entry = null;
        for (self.entries) |*entry| {
            if (entry.sat != sat or t.lessThan(entry.valid_from)) continue;
            if (entry.valid_until) |until| if (until.lessThan(t)) continue;
            if (best) |previous| if (!previous.valid_from.lessThan(entry.valid_from)) continue;
            best = entry;
        }
        return if (best) |entry| entry.centre else null;
    }
};

fn project(ant: *const Antenna, ref: ClockRef) ?PhaseCentre {
    const sat = ant.sat;
    const pair = ref.pair();
    const a = ant.offset(.of(pair[0])) orelse return null;
    const b = ant.offset(.of(pair[1])) orelse return null;
    const f = ref.frequencies();
    const ga = f[0] * f[0];
    const gb = f[1] * f[1];
    var out: PhaseCentre = .{ .reference_m = undefined, .offset_m = @splat(@splat(0)), .law = yaw_law.lawOf(ant.kind) };
    for (0..3) |i| out.reference_m[i] = (ga * a[i] - gb * b[i]) / (ga - gb);
    for (std.enums.values(gnss_types.Signal)) |signal| {
        if (signal.system() != sat.system) continue;
        const own = ant.offset(.of(signal)) orelse continue;
        for (0..3) |i| out.offset_m[signal_catalog.slot(signal)][i] = own[i] - out.reference_m[i];
    }
    return out;
}
