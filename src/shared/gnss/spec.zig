const std = @import("std");
const core_spec = @import("../core.zig").spec;
const types = @import("../core.zig").types;
const gps = @import("gps/signals.zig");
const bds = @import("bds/signals.zig");
const galileo = @import("galileo/signals.zig");
const glonass = @import("glonass/signals.zig");
const bds_records = @import("bds/records.zig");

pub const Spec = core_spec.Spec;
pub const Gain = core_spec.Gain;
pub const Frame = core_spec.Frame;
pub const Code = core_spec.Code;
pub const max_observables = core_spec.max_observables;
const Signal = types.Signal;
const SatId = types.SatId;

const signal_count = std.meta.tags(Signal).len;

const table: [signal_count]Spec = blk: {
    var t: [signal_count]Spec = undefined;
    var seen: [signal_count]bool = @splat(false);
    for (gps.rows ++ bds.rows ++ galileo.rows ++ glonass.rows) |row| {
        const i = @intFromEnum(row.signal);
        if (seen[i]) @compileError("duplicate spec row for " ++ row.signal.name());
        seen[i] = true;
        t[i] = row;
    }
    for (seen, 0..) |s, i| {
        if (!s) @compileError("missing spec row for " ++ @as(Signal, @enumFromInt(i)).name());
    }
    break :blk t;
};

comptime {
    core_spec.check(&table);
}

pub fn get(signal: Signal) *const Spec {
    return &table[@intFromEnum(signal)];
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

pub fn realizedDb(signal: Signal) f64 {
    return realized_db[@intFromEnum(signal)];
}

pub fn frameFor(signal: Signal, sat: SatId) Frame {
    const row = get(signal);
    return row.frameFor(sat.system == .bds and bds_records.isGeo(sat.prn()));
}

pub const max_per_system: usize = blk: {
    var counts = std.EnumArray(types.System, usize).initFill(0);
    for (std.meta.tags(Signal)) |s| counts.getPtr(s.system()).* += 1;
    var most: usize = 0;
    for (counts.values) |n| most = @max(most, n);
    break :blk most;
};

pub fn slot(signal: Signal) usize {
    return slots[@intFromEnum(signal)];
}

const slots: [signal_count]u8 = blk: {
    var next = std.EnumArray(types.System, u8).initFill(0);
    var out: [signal_count]u8 = undefined;
    for (std.meta.tags(Signal), 0..) |s, i| {
        out[i] = next.get(s.system());
        next.getPtr(s.system()).* += 1;
    }
    break :blk out;
};

pub fn nominalCarrierHz(signal: Signal) u64 {
    return switch (get(signal).carrier) {
        .fixed => |f| f,
        .fdma => |p| p.base_hz,
    };
}
