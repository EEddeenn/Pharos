const std = @import("std");
const types = @import("shared").core.types;
const spec = @import("shared").gnss.spec;
const codes = @import("shared").gnss.codes;

pub const Table = struct {
    signal: types.Signal,
    sat: types.SatId,
    states: []const u8,
    entries_per_period: u32,
    entries_per_ms: u32,
    values: [8]spec.Gain,
    value_count: usize = 4,
    tdm: ?Tdm = null,

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
    gpa: std.mem.Allocator,
    tables: []Table,

    pub fn init(gpa: std.mem.Allocator, signals: std.EnumSet(types.Signal)) error{OutOfMemory}!TableSet {
        var count: usize = 0;
        var it = signals.iterator();
        while (it.next()) |signal| count += signal.system().capacity();
        const tables = try gpa.alloc(Table, count);
        errdefer gpa.free(tables);
        var made: usize = 0;
        errdefer for (tables[0..made]) |t| {
            gpa.free(t.states);
            if (t.tdm) |m| gpa.free(m.pilot);
        };
        it = signals.iterator();
        while (it.next()) |signal| {
            const row = spec.get(signal);
            const code = row.code;
            var sats = signal.system().satellites();
            while (sats.next()) |sat| {
                const chips = try codes.dataCode(gpa, signal, sat);
                defer gpa.free(chips);
                const pilot = try codes.pilotCode(gpa, signal, sat);
                const tdm = code.tdm_periods_per_cycle != null;
                defer if (pilot) |p| {
                    if (!tdm) gpa.free(p);
                };
                errdefer if (pilot) |p| {
                    if (tdm) gpa.free(p);
                };
                tables[made] = .{
                    .signal = signal,
                    .sat = sat,
                    .states = try fold(gpa, code, if (row.waveform) |w| w.states else &.{0}, chips, if (tdm) null else pilot),
                    .entries_per_period = code.entriesPerPeriod(),
                    .entries_per_ms = code.entriesPerMs(),
                    .values = valueTable(row),
                    .value_count = row.valueCount(),
                    .tdm = if (code.tdm_periods_per_cycle) |periods| .{ .pilot = pilot.?, .periods = periods, .half = code.entriesPerPeriod() / 2 } else null,
                };
                made += 1;
            }
        }
        return .{ .gpa = gpa, .tables = tables };
    }

    pub fn deinit(self: *TableSet) void {
        for (self.tables) |t| {
            self.gpa.free(t.states);
            if (t.tdm) |m| self.gpa.free(m.pilot);
        }
        self.gpa.free(self.tables);
    }

    pub fn find(self: *const TableSet, key: types.ChannelKey) ?u32 {
        for (self.tables, 0..) |t, i| {
            if (t.signal == key.signal and t.sat == key.sat) return @intCast(i);
        }
        return null;
    }
};

fn valueTable(row: *const spec.Spec) [8]spec.Gain {
    var values: [8]spec.Gain = @splat(.zero);
    for (values[0..row.valueCount()], 0..) |*value, state| value.* = row.stateValue(state);
    return values;
}

fn fold(gpa: std.mem.Allocator, code: spec.Code, pattern: []const u8, data: []const u8, pilot: ?[]const u8) error{OutOfMemory}![]u8 {
    const n = code.entriesPerPeriod();
    const per_chip = code.entriesPerChip();
    const states = try gpa.alloc(u8, n);
    for (states, 0..) |*s, e| {
        const chip = e / per_chip;
        var v: u8 = data[chip % data.len] & 1;
        if (pilot) |p| v |= (p[chip % p.len] & 1) << 1;
        v ^= pattern[e % pattern.len];
        if (code.tdm_periods_per_cycle != null and e % 2 == 1) v = 0;
        s.* = v;
    }
    return states;
}
