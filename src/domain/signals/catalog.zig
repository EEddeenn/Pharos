const std = @import("std");
const core_spec = @import("domain/signals/model");
const gnss_types = @import("domain/gnss_types");
const gps = @import("domain/signals/gps");
const bds = @import("domain/signals/bds");
const galileo = @import("domain/signals/galileo");
const glonass = @import("domain/signals/glonass");
const bds_records = @import("domain/navigation/records/bds");
const Signal = gnss_types.Signal;
const SatId = gnss_types.SatId;

pub const Spec = core_spec.Spec;
pub const Gain = core_spec.Gain;
pub const Frame = core_spec.Frame;
pub const Code = core_spec.Code;
pub const max_observables = core_spec.max_observables;

const signal_count = std.enums.values(Signal).len;

const table: [signal_count]Spec = blk: {
    var t: [signal_count]Spec = undefined;
    var seen: [signal_count]bool = @splat(false);
    for (gps.rows ++ bds.rows ++ galileo.rows ++ glonass.rows) |row| {
        const i = @backingInt(row.signal);
        if (seen[i]) @compileError("duplicate spec row for " ++ row.signal.name());
        seen[i] = true;
        t[i] = row;
    }
    for (seen, 0..) |s, i| {
        if (!s) @compileError("missing spec row for " ++ @as(Signal, @fromBackingInt(@intCast(i))).name());
    }
    break :blk t;
};

comptime {
    core_spec.check(&table);
}

const unity_tolerance = 1e-12;

const realized_db: [signal_count]f64 = blk: {
    @setEvalBranchQuota(100_000);
    var out: [signal_count]f64 = undefined;
    for (table, &out) |row, *db| {
        const p = row.power();
        db.* = if (@abs(p - 1.0) < unity_tolerance) 0 else 10.0 * @log10(p);
    }
    break :blk out;
};

const counts = blk: {
    var out = std.EnumArray(gnss_types.System, usize).initFill(0);
    for (std.enums.values(Signal)) |s| out.getPtr(s.system()).* += 1;
    break :blk out;
};

pub const max_per_system: usize = std.mem.max(usize, &counts.values);

const slots: [signal_count]u8 = blk: {
    var next = std.EnumArray(gnss_types.System, u8).initFill(0);
    var out: [signal_count]u8 = undefined;
    for (std.enums.values(Signal), 0..) |s, i| {
        out[i] = next.get(s.system());
        next.getPtr(s.system()).* += 1;
    }
    break :blk out;
};

pub fn get(signal: Signal) *const Spec {
    return &table[@backingInt(signal)];
}

pub fn realizedDb(signal: Signal) f64 {
    return realized_db[@backingInt(signal)];
}

pub fn frameFor(signal: Signal, sat: SatId) Frame {
    const row = get(signal);
    return row.frameFor(sat.system == .bds and bds_records.isGeo(sat.prn()));
}

pub fn signalCount(system: gnss_types.System) usize {
    return counts.get(system);
}

pub fn slot(signal: Signal) usize {
    return slots[@backingInt(signal)];
}

pub fn nominalCarrierHz(signal: Signal) u64 {
    return switch (get(signal).carrier) {
        .fixed => |f| f,
        .fdma => |p| p.base_hz,
    };
}
