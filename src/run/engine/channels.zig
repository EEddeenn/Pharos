const std = @import("std");
const Io = std.Io;
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const GpsTime = core.time.GpsTime;
const types = core.types;
const Epoch = core.time.Epoch;
const bundle = @import("shared").bundle;
const geo = @import("shared").geo;
const msg = @import("../msg.zig");
const synth = @import("../synth.zig");
const params = synth.params;
const geometry = @import("geometry.zig");
const ChannelTable = @import("channel_table.zig").ChannelTable;
const Channel = @import("channel_table.zig").Channel;
const stage = @import("shared").stage;
const Power = stage.power.Power;
const events = @import("events.zig");

const base_repeat_ms: u32 = 1000;

const mask_slack: usize = 4;
const expand_headroom: f64 = 1.001;

pub const Error = error{ OutOfMemory, Internal, MessageSet, MissingEarthOrientation, MissingTimeOffset, MissingUtcParameters };

fn masksPerChannel(window_epochs: u32, code_ms: u32) usize {
    const rate = 1.0 + params.max_rate_deviation;
    const code: f64 = @floatFromInt(code_ms);
    const base_ms = @ceil(@as(f64, @floatFromInt(window_epochs)) * rate) + base_repeat_ms;
    const starts = @ceil(base_ms / code);
    const stride = @floor(params.sample_stride * rate / code);
    return @as(usize, @intFromFloat(starts + stride)) + mask_slack;
}

const PeriodSpan = struct {
    first: u64 = std.math.maxInt(u64),
    last: u64 = 0,
};

const ParamsDump = struct {
    const Record = struct {
        phase_cycles: f64,
        tx: GpsTime,
        cn0_dbhz: f64,
    };

    writer: *Io.Writer,
    records: []Record,
    enabled: bool = false,

    fn init(gpa: std.mem.Allocator, writer: *Io.Writer, count: usize) error{OutOfMemory}!ParamsDump {
        return .{ .writer = writer, .records = try gpa.alloc(Record, count) };
    }

    fn deinit(self: ParamsDump, gpa: std.mem.Allocator) void {
        gpa.free(self.records);
    }

    fn write(self: ParamsDump, source: *const Stage) Io.Writer.Error!void {
        var e: u32 = 0;
        while (e < source.window_count) : (e += 1) {
            const epoch = source.window_first.plus(e);
            const side = self.records[e * source.window_channels ..][0..source.window_channels];
            for (source.epochRows(e), side, 0..) |maybe, d, ci| {
                const row = maybe orelse continue;
                const c = source.table.channels.items[ci];
                try self.writer.print("{d} {d} {f} {f} {d} {f} {f} {f} {f} {f} {d} {f} {d} {f}\n", .{
                    epoch.ms, core.time.atEpoch(source.start, epoch).ms, c.key, core.hex.double(d.phase_cycles), d.tx.ms, core.hex.double(d.tx.sub_ms), core.hex.double(row.carrier_phase0), core.hex.double(row.carrier_step), core.hex.double(row.entry_phase0), core.hex.double(row.entries_per_sample), row.period0, core.hex.double(d.cn0_dbhz), row.lead_bits, core.hex.double(row.lead_entries),
                });
            }
        }
    }
};

pub const Stage = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    b: *const bundle.Bundle,
    start: GpsTime,
    samples_per_epoch: u32,
    window_epochs: u32,
    tables: synth.tables.TableSet,
    table: ChannelTable,
    seq: stage.sequence.Sequence,
    log: stage.commands.Log = .{},
    sats: []types.SatId,
    sights: []?stage.channels.Sight,
    streams: msg.streams.Streams,
    rows: []?params.EpochParams,
    spans: []PeriodSpan,
    masks: []u8,
    masks_per_channel: usize,
    window_first: Epoch = .zero,
    window_count: u32 = 0,
    window_channels: usize = 0,
    dump_params: ?ParamsDump,
    dump_plan: ?*Io.Writer = null,

    pub const Options = struct {
        samples: bundle.scenario.Samples,
        window_epochs: u32,
        dump_params: ?*Io.Writer = null,
    };

    pub fn init(gpa: std.mem.Allocator, b: *const bundle.Bundle, resolved: geometry.Resolved, opts: Options) error{ OutOfMemory, MessageSet }!*Stage {
        const scenario = &b.scenario;
        const allocation = resolved.allocation;
        const window_epochs = opts.window_epochs;
        const samples = opts.samples;
        const self = try gpa.create(Stage);
        errdefer gpa.destroy(self);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var table_set = try synth.tables.TableSet.init(gpa, scenario.signals);
        errdefer table_set.deinit();
        var capacity: usize = 0;
        var min_code_ms: u32 = core.time.ms_per_second;
        var it = scenario.signals.iterator();
        while (it.next()) |signal| {
            capacity += signal.system().capacity();
            min_code_ms = @min(min_code_ms, gnss.spec.get(signal).code.data_period_ms);
        }
        const sats = try gpa.alloc(types.SatId, resolved.tracks.len);
        errdefer gpa.free(sats);
        for (sats, resolved.tracks) |*sat, track| sat.* = track.sat;
        const sights = try gpa.alloc(?stage.channels.Sight, sats.len);
        errdefer gpa.free(sights);
        var failure: stage.messages.PreparationFailure = undefined;
        const prepared = stage.messages.Messages.prepare(arena.allocator(), scenario.messages, stage.messages.familiesOf(scenario.signals), scenario.start, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPublication => return error.MessageSet,
        };
        var seq = try stage.sequence.Sequence.init(gpa, prepared, b, allocation, resolved.broadcast, samples, &self.log, sats);
        errdefer seq.deinit(gpa);
        const rows = try gpa.alloc(?params.EpochParams, window_epochs * capacity);
        errdefer gpa.free(rows);
        const dump_params: ?ParamsDump = if (opts.dump_params) |writer| try ParamsDump.init(gpa, writer, rows.len) else null;
        errdefer if (dump_params) |dump| dump.deinit(gpa);
        const spans = try gpa.alloc(PeriodSpan, capacity);
        errdefer gpa.free(spans);
        const masks_per_channel = masksPerChannel(window_epochs, min_code_ms);
        const masks = try gpa.alloc(u8, masks_per_channel * capacity);
        errdefer gpa.free(masks);
        var streams = try msg.streams.Streams.init(gpa, b, allocation, seq.prepared, resolved.models.get(.bds));
        errdefer streams.deinit(gpa);
        self.* = .{
            .gpa = gpa,
            .arena = arena,
            .b = b,
            .start = scenario.start,
            .samples_per_epoch = samples.sample_rate.samplesPerEpoch(),
            .window_epochs = window_epochs,
            .tables = table_set,
            .table = ChannelTable.init(gpa, samples.center),
            .seq = seq,
            .sats = sats,
            .sights = sights,
            .streams = streams,
            .rows = rows,
            .dump_params = dump_params,
            .spans = spans,
            .masks = masks,
            .masks_per_channel = masks_per_channel,
        };
        try self.reset();
        return self;
    }

    pub fn deinit(self: *Stage) void {
        self.streams.deinit(self.gpa);
        self.log.deinit(self.gpa);
        self.seq.deinit(self.gpa);
        self.gpa.free(self.sights);
        self.gpa.free(self.sats);
        self.table.deinit();
        self.gpa.free(self.masks);
        self.gpa.free(self.spans);
        if (self.dump_params) |dump| dump.deinit(self.gpa);
        self.gpa.free(self.rows);
        self.tables.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn reset(self: *Stage) error{MessageSet}!void {
        self.table.reset();
        self.streams.reset();
        self.dump_plan = null;
        if (self.dump_params) |*dump| dump.enabled = false;
        try self.seq.reset(self.streams.sources());
    }

    fn refreshSets(self: *Stage, due: stage.sequence.Due) Error!void {
        for (self.table.channels.items) |*c| {
            if (c.last_epoch == null and due.families.contains(gnss.spec.get(c.key.signal).family)) c.symbols.adopt();
        }
        try self.seq.refresh(due, self.streams.sources());
        const snap = self.seq.snapshot();
        for (self.table.channels.items) |*c| {
            if (c.last_epoch != null or !due.families.contains(gnss.spec.get(c.key.signal).family)) continue;
            if (stage.messages.forSignal(snap, c.key.signal)) |messages| c.symbols.replaceSet(messages);
        }
    }

    fn refreshDue(self: *Stage, first: Epoch, count: u32, geom: *const geometry.Stage, ring: *events.Ring) Error!void {
        var e = first;
        while (e.ms < first.ms + count) : (e = e.plus(1)) {
            const t = core.time.atEpoch(self.start, e);
            while (self.seq.due(t)) |due| try self.refreshSets(due);
            if (@mod(e.ms, stage.channels.replan_epochs) == 0) {
                const rows = geom.rowsAt(e) orelse return error.Internal;
                for (rows, self.sights) |row, *sight| sight.* = if (row.seen) |seen| .{ .record = seen.delays.record, .el_rad = seen.epoch.el_rad } else null;
                try self.seq.replan(self.sights, e);
                const before = self.table.changes;
                try self.table.apply(e, self.seq.changes.items, rows, &self.tables, self.seq.snapshot(), ring);
                if (self.table.changes != before) if (self.dump_plan) |w| self.dumpPlan(w, e) catch {};
            }
        }
    }

    fn deriveEpoch(self: *Stage, e: Epoch, offset: usize, channels: []const Channel, rows_a: []const geometry.Row, rows_b: []const geometry.Row, power: *const Power) void {
        const out = self.rows[offset..][0..channels.len];
        for (channels, out, self.spans[0..channels.len], 0..) |*c, *row, *span, ci| {
            row.* = null;
            if (!c.activeAt(e)) continue;
            const a: *const geometry.Row.Seen = if (rows_a[c.track].seen) |*seen| seen else continue;
            const b: *const geometry.Row.Seen = if (rows_b[c.track].seen) |*seen| seen else continue;
            const signal = c.key.signal;
            const gd = a.delays.code(signal, .data);
            const gp = a.delays.code(signal, .pilot);
            const code_s = @max(gd, gp);
            const code_b = @max(b.delays.code(signal, .data), b.delays.code(signal, .pilot));
            const endpoint_a = params.Endpoint{
                .phase_cycles = geo.observation.channelPhase(a.epoch, signal, c.freq, a.delays.carrier(signal)),
                .tx = geo.observation.transmitTime(a.epoch, signal, c.freq, code_s),
            };
            const endpoint_b = params.Endpoint{
                .phase_cycles = geo.observation.channelPhase(b.epoch, signal, c.freq, b.delays.carrier(signal)),
                .tx = geo.observation.transmitTime(b.epoch, signal, c.freq, code_b),
            };
            const cn0 = power.cn0(c.key.sat, a.epoch.el_rad);
            if (self.dump_params) |dump| if (dump.enabled) {
                dump.records[offset + ci] = .{ .phase_cycles = endpoint_a.phase_cycles, .tx = endpoint_a.tx, .cn0_dbhz = cn0 };
            };
            var p = params.derive(c.synth, self.b.plan.leap, endpoint_a, endpoint_b, core.time.atEpoch(self.start, e), self.samples_per_epoch, cn0) orelse continue;
            if (gp != gd) {
                p.lead_bits = gnss.spec.get(signal).stateBits(if (gp < gd) .pilot else .data);
                p.lead_entries = params.leadEntries(c.synth, code_s, @min(gd, gp));
            }
            const needed = p.masksNeeded(self.samples_per_epoch, self.tables.tables[c.synth.table].entries_per_period);
            span.first = @min(span.first, p.period0);
            span.last = @max(span.last, p.period0 + needed);
            row.* = p;
        }
    }

    fn bindMasks(self: *Stage, c: *Channel, ci: usize, span: PeriodSpan) error{Internal}!void {
        const slot = self.masks[ci * self.masks_per_channel ..][0..self.masks_per_channel];
        const len: usize = @intCast(span.last - span.first);
        if (len > slot.len) return error.Internal;
        c.symbols.fill(span.first, slot[0..len]);
        for (0..self.window_count) |i| {
            if (self.rows[i * self.window_channels + ci]) |*row| row.masks = slot[@intCast(row.period0 - span.first)..len];
        }
    }

    pub fn prepare(self: *Stage, first: Epoch, count: u32, geom: *const geometry.Stage, power: *const Power, ring: *events.Ring) Error!void {
        std.debug.assert(count <= self.window_epochs);
        self.streams.advanceTo(core.time.atEpoch(self.start, first.plus(count)));
        self.table.prune(first);
        try self.refreshDue(first, count, geom, ring);
        const channels = self.table.channels.items;
        self.window_first = first;
        self.window_count = count;
        self.window_channels = channels.len;
        std.debug.assert(self.rows.len >= count * channels.len);
        @memset(self.spans[0..channels.len], .{});
        for (0..count) |i| {
            const e = first.plus(i);
            const rows_a = geom.rowsAt(e) orelse return error.Internal;
            const rows_b = geom.rowsAt(e.plus(1)) orelse return error.Internal;
            self.deriveEpoch(e, i * channels.len, channels, rows_a, rows_b, power);
        }
        for (channels, self.spans[0..channels.len], 0..) |*c, span, ci| {
            if (span.last != 0) try self.bindMasks(c, ci, span);
        }
        if (self.dump_params) |dump| if (dump.enabled) dump.write(self) catch {};
    }

    pub fn epochRows(self: *const Stage, index: u32) []const ?params.EpochParams {
        std.debug.assert(index < self.window_count);
        return self.rows[index * self.window_channels ..][0..self.window_channels];
    }

    pub fn maxSamplesPerEntry(self: *const Stage) f64 {
        var min_entries: u32 = std.math.maxInt(u32);
        for (self.tables.tables) |t| min_entries = @min(min_entries, t.entries_per_ms);
        if (min_entries == std.math.maxInt(u32)) return 1.0;
        return @as(f64, @floatFromInt(self.samples_per_epoch)) / @as(f64, @floatFromInt(min_entries)) * expand_headroom;
    }

    fn dumpPlan(self: *const Stage, w: *Io.Writer, epoch: Epoch) Io.Writer.Error!void {
        try w.print("{d}:", .{epoch.ms});
        for (self.table.channels.items) |c| {
            if (c.last_epoch != null) continue;
            try w.print(" {f}@{d}", .{ c.key, c.synth.if_hz });
        }
        try w.writeAll("\n");
    }
};
