const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const signal_catalog = @import("domain/signals/catalog");
const codes = @import("domain/signals/codes/generate");

pub const Axis = enum { both, re, im };
pub const ValueCount = enum { four, eight };

pub const Table = struct {
    signal: gnss_types.Signal,
    sat: gnss_types.SatId,
    states: []const u8,
    entries_per_period: u32,
    entries_per_ms: u32,
    values: [8]signal_catalog.Gain,
    value_count: ValueCount,
    tdm: ?Tdm,
    axis: Axis,

    const Tdm = struct {
        pilot: []const u8,
        periods: u32,
        half: u32,

        pub fn index(self: Tdm, period: u64, e: u32) u32 {
            return @intCast((period % self.periods) * self.half + e / 2);
        }
    };
};

pub const TableSet = struct {
    tables: []Table,

    pub fn init(gpa: std.mem.Allocator, keys: []const gnss_types.ChannelKey) error{OutOfMemory}!TableSet {
        const tables = try gpa.alloc(Table, keys.len);
        errdefer gpa.free(tables);
        var made: usize = 0;
        errdefer for (tables[0..made]) |t| {
            gpa.free(t.states);
            if (t.tdm) |m| gpa.free(m.pilot);
        };
        for (keys) |key| {
            const signal = key.signal;
            const sat = key.sat;
            const row = signal_catalog.get(signal);
            const values = valueTable(row);
            const chips = try codes.dataCode(gpa, signal, sat);
            defer gpa.free(chips);
            const pilot = try codes.pilotCode(gpa, signal, sat);
            const tdm = row.tdmPeriods() != null;
            defer if (pilot) |p| {
                if (!tdm) gpa.free(p);
            };
            errdefer if (pilot) |p| {
                if (tdm) gpa.free(p);
            };
            tables[made] = .{
                .signal = signal,
                .sat = sat,
                .states = try fold(gpa, row, chips, if (tdm) null else pilot),
                .entries_per_period = row.entriesPerPeriod(),
                .entries_per_ms = row.entriesPerMs(),
                .values = values,
                .value_count = if (row.valueCount() == 4) .four else .eight,
                .tdm = if (row.tdmPeriods()) |periods| .{ .pilot = pilot.?, .periods = periods, .half = row.entriesPerPeriod() / 2 } else null,
                .axis = axisOf(values),
            };
            made += 1;
        }
        return .{ .tables = tables };
    }

    pub fn deinit(self: *TableSet, gpa: std.mem.Allocator) void {
        for (self.tables) |t| {
            gpa.free(t.states);
            if (t.tdm) |m| gpa.free(m.pilot);
        }
        gpa.free(self.tables);
    }

    pub fn find(self: *const TableSet, key: gnss_types.ChannelKey) ?u32 {
        for (self.tables, 0..) |t, i| {
            if (t.signal == key.signal and t.sat == key.sat) return @intCast(i);
        }
        return null;
    }
};

fn axisOf(values: [8]signal_catalog.Gain) Axis {
    var any_re = false;
    var any_im = false;
    for (values) |v| {
        any_re = any_re or v.re != 0;
        any_im = any_im or v.im != 0;
    }
    if (!any_im) return .re;
    if (!any_re) return .im;
    return .both;
}

fn valueTable(row: *const signal_catalog.Spec) [8]signal_catalog.Gain {
    var values: [8]signal_catalog.Gain = @splat(.zero);
    for (values[0..row.valueCount()], 0..) |*value, state| value.* = row.stateValue(state);
    return values;
}

fn fold(gpa: std.mem.Allocator, row: *const signal_catalog.Spec, data: []const u8, pilot: ?[]const u8) error{OutOfMemory}![]u8 {
    const n = row.entriesPerPeriod();
    const per_chip = row.entriesPerChip();
    const pattern = row.subcarrierStates();
    const states = try gpa.alloc(u8, n);
    for (states, 0..) |*s, e| {
        const chip = e / per_chip;
        var v: u8 = data[chip % data.len] & 1;
        if (pilot) |p| v |= (p[chip % p.len] & 1) << 1;
        v ^= pattern[e % pattern.len];
        if (row.tdmPeriods() != null and e % 2 == 1) v = 0;
        s.* = v;
    }
    return states;
}
