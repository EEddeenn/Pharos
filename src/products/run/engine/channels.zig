const std = @import("std");
const channel_table = @import("products/run/engine/channel_table");
const time = @import("domain/time/gps");
const flight = @import("simulation/model/flight_plan");
const configuration = @import("simulation/model/config");
const signal_catalog = @import("domain/signals/catalog");
const hex = @import("base/text/hex");
const track_binding = @import("simulation/tracking/binding");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const trajectory = @import("domain/trajectory/trajectory");
const civil = @import("domain/time/civil");
const code_tables = @import("products/run/synthesis/code_tables");
const sequence = @import("simulation/state/sequence");
const command_log = @import("simulation/state/commands");
const channel_selection = @import("simulation/state/channels");
const services = @import("products/run/services/streams");
const message_sets = @import("simulation/state/messages");
const observation_model = @import("simulation/geometry/observation");
const gnss_types = @import("domain/gnss_types");
const params = @import("products/run/synthesis/parameters");
const geometry = @import("products/run/engine/geometry");
const events = @import("products/run/engine/events");

const PreparedMessages = @import("simulation/model/prepared_messages").PreparedMessages;
const ServicePlan = @import("simulation/model/services").ServicePlan;
const Payload = @import("domain/signals/payload").Payload;
const Power = @import("simulation/state/power").Power;

const Io = std.Io;
const GpsTime = time.GpsTime;
const Epoch = time.Epoch;
const ChannelTable = channel_table.ChannelTable;
const Channel = channel_table.Channel;

const base_repeat_ms: u32 = 1000;

const mask_slack: usize = 4;
const expand_headroom: f64 = 1.001;

pub const Error = error{Internal};

const PeriodSpan = struct {
    first: u64 = std.math.maxInt(u64),
    last: u64 = 0,

    fn include(self: *PeriodSpan, p: params.EpochParams, samples_per_epoch: u32, entries_per_period: u32) void {
        self.first = @min(self.first, p.period0);
        self.last = @max(self.last, p.period0 + p.masksNeeded(samples_per_epoch, entries_per_period));
    }
};

const ParamsDump = struct {
    writer: *Io.Writer,
    records: []Record,

    const Record = struct {
        phase_cycles: f64,
        tx: GpsTime,
        cn0_dbhz: f64,
    };

    fn init(gpa: std.mem.Allocator, writer: *Io.Writer, count: usize) error{OutOfMemory}!ParamsDump {
        return .{ .writer = writer, .records = try gpa.alloc(Record, count) };
    }

    fn deinit(self: ParamsDump, gpa: std.mem.Allocator) void {
        gpa.free(self.records);
    }

    fn write(self: ParamsDump, source: *const Channels) Io.Writer.Error!void {
        var e: u32 = 0;
        while (e < source.window.?.epochs) : (e += 1) {
            const epoch = source.window.?.first.plus(e);
            const side = self.records[e * source.window.?.channels ..][0..source.window.?.channels];
            for (source.epochRows(e), side, 0..) |maybe, d, ci| {
                const row = maybe orelse continue;
                const c = source.active.channels.items[ci];
                try self.writer.print("{d} {d} {f} {f} {d} {f} {f} {f} {f} {f} {d} {f} {d} {f}\n", .{
                    epoch.ms, time.atEpoch(source.start, epoch).ms, c.key, hex.double(d.phase_cycles), d.tx.ms, hex.double(d.tx.sub_ms), hex.double(row.carrier_phase0), hex.double(row.carrier_step), hex.double(row.entry_phase0), hex.double(row.entries_per_sample), row.period0, hex.double(d.cn0_dbhz), row.lead_bits, hex.double(row.lead_entries),
                });
            }
        }
    }
};

pub const Inputs = struct {
    ephemerides: track_binding.Inputs,
    prepared: *const PreparedMessages,
    service_plan: ServicePlan,
    payload: *const Payload,
    trajectory: *const trajectory.Trajectory,
    start: GpsTime,
    signals: std.EnumSet(gnss_types.Signal),
    elevation_mask_rad: f64,
    has: ?configuration.Has,
    ppp_b2b: ?configuration.PppB2b,
    samples: configuration.Samples,
    window_epochs: u32,
};

pub const DumpWriters = struct { params: ?*Io.Writer = null, plan: ?*Io.Writer = null };
const Window = struct { first: Epoch, epochs: u32, channels: usize, rows: []const ?geometry.Row };

pub const Channels = struct {
    gpa: std.mem.Allocator,
    leap: civil.Leap,
    start: GpsTime,
    samples_per_epoch: u32,
    codes: code_tables.TableSet,
    active: ChannelTable,
    selection: channel_selection.Selection,
    messages: sequence.MessageSequence,
    log: command_log.Log = .{},
    sats: []gnss_types.SatId,
    sights: []?channel_selection.Sight,
    streams: services.Streams,
    parameters: []?params.EpochParams,
    spans: []PeriodSpan,
    precomputed: []bool,
    masks: []u8,
    masks_per_channel: usize,
    window: ?Window = null,
    symbols_skipped: bool = false,
    dump_params: ?ParamsDump,
    dump_plan: ?*Io.Writer,

    pub fn create(gpa: std.mem.Allocator, input: Inputs, satellites: []const gnss_types.SatId, bds_model: *const ionosphere_model.Model, dumps: DumpWriters) error{OutOfMemory}!*Channels {
        const self = try gpa.create(Channels);
        errdefer gpa.destroy(self);
        const samples = input.samples;
        const sats = try gpa.dupe(gnss_types.SatId, satellites);
        errdefer gpa.free(sats);
        var selection = try channel_selection.Selection.init(gpa, .{ .payload = input.payload, .samples = samples }, input.signals, input.elevation_mask_rad, &self.log, sats);
        errdefer selection.deinit(gpa);
        const capacity = selection.held.capacity;
        var active = try ChannelTable.init(gpa, capacity, samples.center);
        errdefer active.deinit(gpa);
        var keys: std.ArrayList(gnss_types.ChannelKey) = .empty;
        defer keys.deinit(gpa);
        var min_code_ms: u32 = time.ms_per_second;
        var it = input.signals.iterator();
        while (it.next()) |signal| {
            min_code_ms = @min(min_code_ms, signal_catalog.get(signal).code.period_ms);
            var satellites_of_system = signal.system().satellites();
            while (satellites_of_system.next()) |sat| {
                const key: gnss_types.ChannelKey = .{ .sat = sat, .signal = signal };
                if (needsTable(input.ephemerides.flight_plan, samples, key)) try keys.append(gpa, key);
            }
        }
        var codes = try code_tables.TableSet.init(gpa, keys.items);
        errdefer codes.deinit(gpa);
        const sights = try gpa.alloc(?channel_selection.Sight, sats.len);
        errdefer gpa.free(sights);
        const parameters = try gpa.alloc(?params.EpochParams, input.window_epochs * capacity);
        errdefer gpa.free(parameters);
        const dump_params: ?ParamsDump = if (dumps.params) |writer| try ParamsDump.init(gpa, writer, parameters.len) else null;
        errdefer if (dump_params) |dump| dump.deinit(gpa);
        const spans = try gpa.alloc(PeriodSpan, capacity);
        errdefer gpa.free(spans);
        const precomputed = try gpa.alloc(bool, capacity);
        errdefer gpa.free(precomputed);
        const masks_per_channel = masksPerChannel(input.window_epochs, min_code_ms);
        const masks = try gpa.alloc(u8, masks_per_channel * capacity);
        errdefer gpa.free(masks);
        var streams = try services.Streams.init(gpa, .{
            .ephemerides = input.ephemerides,
            .trajectory = input.trajectory,
            .start = input.start,
            .signals = input.signals,
            .publications = &input.prepared.publications,
            .plan = input.service_plan,
            .has = input.has,
            .ppp_b2b = input.ppp_b2b,
        }, input.payload, bds_model);
        errdefer streams.deinit(gpa);
        var messages = try sequence.MessageSequence.init(gpa, .{
            .navigation = .{ .flight_plan = input.ephemerides.flight_plan, .messages = input.prepared },
            .start = input.start,
            .families = input.payload.families(input.signals),
        }, streams.suppliers());
        errdefer messages.deinit(gpa);
        self.* = .{
            .gpa = gpa,
            .leap = input.ephemerides.flight_plan.leap,
            .start = input.start,
            .samples_per_epoch = samples.sample_rate.samplesPerEpoch(),
            .codes = codes,
            .active = active,
            .selection = selection,
            .messages = messages,
            .sats = sats,
            .sights = sights,
            .streams = streams,
            .parameters = parameters,
            .dump_params = dump_params,
            .dump_plan = dumps.plan,
            .spans = spans,
            .precomputed = precomputed,
            .masks = masks,
            .masks_per_channel = masks_per_channel,
        };
        return self;
    }

    pub fn destroy(self: *Channels) void {
        self.messages.deinit(self.gpa);
        self.streams.deinit(self.gpa);
        self.selection.deinit(self.gpa);
        self.log.deinit(self.gpa);
        self.gpa.free(self.sights);
        self.gpa.free(self.sats);
        self.active.deinit(self.gpa);
        self.gpa.free(self.masks);
        self.gpa.free(self.spans);
        self.gpa.free(self.precomputed);
        if (self.dump_params) |dump| dump.deinit(self.gpa);
        self.gpa.free(self.parameters);
        self.codes.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn reset(self: *Channels) void {
        self.symbols_skipped = false;
        self.window = null;
        self.active.reset();
        self.selection.reset();
        self.streams.reset();
        self.messages.reset();
    }

    pub fn plan(self: *Channels, first: Epoch, count: u32, geom: *const geometry.Geometry, ring: *events.Ring) geometry.WindowRows {
        self.streams.advanceTo(time.atEpoch(self.start, first.plus(count)));
        const rows = geom.rowsFor(first, count);
        while (self.messages.due(time.atEpoch(self.start, first))) |due| self.refreshSets(due);
        // Re-plans open blocks, which no window crosses.
        if (@mod(first.ms, channel_selection.replan_epochs) == 0) {
            switch (rows) {
                .skipped => for (geom.observation.entries, self.sights) |*entry, *sight| {
                    sight.* = if (entry.geometry) |g| .{ .air = entry.delays.air, .freq = entry.delays.freq, .el_rad = g.knots[0].el_rad } else null;
                },
                .dense, .endpoints => |values| for (values[0..self.sats.len], self.sights) |maybe, *sight| {
                    sight.* = if (maybe) |seen| .{ .air = seen.delays.air, .freq = seen.delays.freq, .el_rad = seen.epoch.el_rad } else null;
                },
            }
            self.selection.replan(self.sights, first);
            if (self.active.apply(first, self.selection.changes.items, self.sats, &self.codes, self.messages.currentSets(), self.selection.rules.payload, ring)) {
                if (self.dump_plan) |writer| self.dumpPlan(writer, first) catch {};
            }
        }
        while (self.messages.due(time.atEpoch(self.start, first.plus(count - 1)))) |due| self.refreshSets(due);
        return rows;
    }

    pub fn deriveEpoch(self: *const Channels, i: u32, power: *const Power) void {
        const channels = self.active.channels.items;
        const out = self.parameters[i * channels.len ..][0..channels.len];
        for (channels, out, self.spans[0..channels.len], self.precomputed[0..channels.len], 0..) |*c, *row, span, derived, ci| {
            if (derived) continue;
            row.* = self.deriveOne(i, c, ci, power);
            if (row.*) |*p| {
                std.debug.assert(p.period0 >= span.first and p.period0 + p.masksNeeded(self.samples_per_epoch, self.codes.tables[c.synth.table].entries_per_period) <= span.last);
                self.bind(p, ci, span);
            }
        }
    }

    pub fn prepare(self: *Channels, first: Epoch, count: u32, geom: *const geometry.Geometry, power: *const Power, ring: *events.Ring) Error!void {
        const view = self.plan(first, count, geom, ring);
        const channels = self.active.channels.items;
        const geometry_rows = switch (view) {
            .skipped => {
                self.symbols_skipped = true;
                self.window = null;
                return;
            },
            .dense, .endpoints => |rows| rows,
        };
        self.window = .{ .first = first, .epochs = count, .channels = channels.len, .rows = geometry_rows };
        std.debug.assert(self.parameters.len >= count * channels.len);
        defer self.symbols_skipped = false;
        const here = self.dump_params != null or count <= 2;
        const ends_only = view == .endpoints;
        for (channels, self.spans[0..channels.len], self.precomputed[0..channels.len], 0..) |*c, *span, *derived, ci| {
            const per = self.codes.tables[c.synth.table].entries_per_period;
            span.* = .{};
            // A channel's periods only grow, so its first and last epochs give the window's span; the job derives every epoch.
            derived.* = here or for ([_]u32{ 0, count - 1 }) |i| {
                span.include(self.deriveOne(i, c, ci, power) orelse break true, self.samples_per_epoch, per);
            } else false;
            // A valid precise clock can drive the transmit-time rate outside the synthesis range. An endpoint-only
            // seek cannot recover those parameters from the omitted interior rows.
            if (derived.* and ends_only and self.window.?.rows[c.track] != null) return error.Internal;
            if (derived.*) {
                span.* = .{};
                for (0..count) |i| {
                    const row = &self.parameters[i * channels.len + ci];
                    row.* = self.deriveOne(i, c, ci, power);
                    if (row.*) |p| span.include(p, self.samples_per_epoch, per);
                }
            }
            if (span.last == 0) continue;
            if (self.symbols_skipped and c.first_epoch.ms != first.ms) c.symbols.catchUp(span.first);
            self.fillMasks(c, ci, span.*);
            if (derived.*) for (0..count) |i| {
                if (self.parameters[i * channels.len + ci]) |*p| self.bind(p, ci, span.*);
            };
        }
        if (self.dump_params) |dump| dump.write(self) catch {};
    }

    pub fn epochRows(self: *const Channels, index: u32) []const ?params.EpochParams {
        std.debug.assert(index < self.window.?.epochs);
        return self.parameters[index * self.window.?.channels ..][0..self.window.?.channels];
    }

    pub fn maxSamplesPerEntry(self: *const Channels) f64 {
        var min_entries: u32 = std.math.maxInt(u32);
        for (self.codes.tables) |t| min_entries = @min(min_entries, t.entries_per_ms);
        if (min_entries == std.math.maxInt(u32)) return 1.0;
        return @as(f64, @floatFromInt(self.samples_per_epoch)) / @as(f64, @floatFromInt(min_entries)) * expand_headroom;
    }

    fn refreshSets(self: *Channels, due: sequence.Due) void {
        self.messages.refresh(due);
        const sets = self.messages.currentSets();
        for (self.active.channels.items) |*channel| {
            const messages = message_sets.forChannel(sets, self.selection.rules.payload, channel.key).?;
            if (due.families.contains(std.meta.activeTag(messages))) channel.symbols.replaceSet(messages);
        }
    }

    fn deriveOne(self: *const Channels, i: usize, c: *const Channel, ci: usize, power: *const Power) ?params.EpochParams {
        const e = self.window.?.first.plus(i);
        const tracks = self.sats.len;
        const a: *const geometry.Row = if (self.window.?.rows[i * tracks + c.track]) |*seen| seen else return null;
        const b: *const geometry.Row = if (self.window.?.rows[(i + 1) * tracks + c.track]) |*seen| seen else return null;
        const signal = c.key.signal;
        const gd = a.delays.code(signal, .data);
        const gp = a.delays.code(signal, .pilot);
        const code_s = @max(gd, gp);
        const code_b = @max(b.delays.code(signal, .data), b.delays.code(signal, .pilot));
        const endpoint_a = params.Endpoint{
            .phase_cycles = observation_model.channelPhase(a.epoch, signal, c.freq, a.delays.carrier(signal)),
            .tx = observation_model.transmitTime(a.epoch, signal, c.freq, code_s),
        };
        const endpoint_b = params.Endpoint{
            .phase_cycles = observation_model.channelPhase(b.epoch, signal, c.freq, b.delays.carrier(signal)),
            .tx = observation_model.transmitTime(b.epoch, signal, c.freq, code_b),
        };
        const cn0 = power.cn0(c.key.sat, a.epoch.el_rad);
        if (self.dump_params) |dump| dump.records[i * self.window.?.channels + ci] = .{ .phase_cycles = endpoint_a.phase_cycles, .tx = endpoint_a.tx, .cn0_dbhz = cn0 };
        var p = params.derive(c.synth, self.leap, endpoint_a, endpoint_b, time.atEpoch(self.start, e), self.samples_per_epoch, cn0) orelse return null;
        if (gp != gd) {
            p.lead_bits = signal_catalog.get(signal).stateBits(if (gp < gd) .pilot else .data);
            p.lead_entries = params.leadEntries(c.synth, code_s, @min(gd, gp));
        }
        return p;
    }

    fn bind(self: *const Channels, p: *params.EpochParams, ci: usize, span: PeriodSpan) void {
        const slot = self.masks[ci * self.masks_per_channel ..];
        p.masks = slot[@intCast(p.period0 - span.first)..@intCast(span.last - span.first)];
    }

    fn fillMasks(self: *Channels, c: *Channel, ci: usize, span: PeriodSpan) void {
        const slot = self.masks[ci * self.masks_per_channel ..][0..self.masks_per_channel];
        const len: usize = @intCast(span.last - span.first);
        std.debug.assert(len <= slot.len);
        c.symbols.fill(span.first, slot[0..len]);
    }

    fn dumpPlan(self: *const Channels, w: *Io.Writer, epoch: Epoch) Io.Writer.Error!void {
        try w.print("{d}:", .{epoch.ms});
        for (self.active.channels.items) |c| {
            try w.print(" {f}@{d}", .{ c.key, c.synth.if_hz });
        }
        try w.writeAll("\n");
    }
};

fn masksPerChannel(window_epochs: u32, code_ms: u32) usize {
    const rate = 1.0 + params.max_rate_deviation;
    const code: f64 = @floatFromInt(code_ms);
    const base_ms = @ceil(@as(f64, @floatFromInt(window_epochs)) * rate) + base_repeat_ms;
    const starts = @ceil(base_ms / code);
    const stride = @floor(params.sample_stride * rate / code);
    return @as(usize, @intFromFloat(starts + stride)) + mask_slack;
}

fn needsTable(flight_plan: *const flight.FlightPlan, samples: configuration.Samples, key: gnss_types.ChannelKey) bool {
    for (flight_plan.timelines[flight.slot(key.sat)].legs) |leg| {
        const binding = leg.binding orelse continue;
        if (binding.air[signal_catalog.slot(key.signal)].status != .on_air) continue;
        if (samples.inBand(signal_catalog.get(key.signal).carrierHz(binding.freq))) return true;
    }
    return false;
}
