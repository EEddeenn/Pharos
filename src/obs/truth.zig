const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const bundle = shared.bundle;
const stage = shared.stage;
const types = core.types;
const coord = core.coord;
const Epoch = core.time.Epoch;
const Power = stage.power.Power;
const channels = stage.channels;
const inspect_values = @import("inspect.zig");
const sky_values = @import("truth/sky.zig");
const Replay = @import("truth/replay.zig").Replay;

pub const Error = error{OutOfMemory};
pub const QueryError = error{ OutOfMemory, EpochOutOfRange, NoSamples } || stage.messages.Failure;
pub const SubmitError = error{ OutOfMemory, InvalidValue };
pub const InspectError = QueryError || error{InvalidValue};

pub const Satellite = sky_values.Satellite;
pub const Dop = sky_values.Dop;

pub const Signal = struct {
    sat: types.SatId,
    signal: types.Signal,
    state: channels.State,
    commanded: bool,
    cn0_dbhz: f64,
};

pub const Sky = struct {
    pos: coord.Ecef,
    vel: coord.Ecef,
    lla: coord.Lla,
    mask_rad: f64,
    dop: ?Dop,
    satellites: []const Satellite,
    signals: []const Signal,
};

pub const Truth = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    b: *const bundle.Bundle,
    span: bundle.Span,
    allocation: gnss.allocation.Allocation,
    power: Power,
    power_epoch: ?Epoch = null,
    next_power: usize = 0,
    log: stage.commands.Log = .{},
    geometry: sky_values.Sky,
    replay: ?Replay = null,
    prepared: ?stage.messages.Messages = null,
    signals: []Signal,
    system_signals: std.EnumArray(types.System, std.EnumSet(types.Signal)),
    full: ?Sky = null,
    full_epoch: ?Epoch = null,

    pub fn create(gpa: std.mem.Allocator, b: *const bundle.Bundle) Error!*Truth {
        const self = try gpa.create(Truth);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .b = b,
            .span = b.span(),
            .allocation = gnss.allocation.at(b.scenario.start),
            .power = Power.init(b.scenario.power),
            .geometry = undefined,
            .signals = &.{},
            .system_signals = .initFill(.empty),
        };
        errdefer self.arena.deinit();
        var it = b.scenario.signals.iterator();
        while (it.next()) |signal| self.system_signals.getPtr(signal.system()).insert(signal);
        self.geometry = try sky_values.Sky.init(gpa, b, &self.allocation);
        errdefer self.geometry.deinit();
        var count: usize = 0;
        if (b.scenario.samples != null) {
            for (self.geometry.window.tracks) |track| count += self.system_signals.get(track.sat.system).count();
        }
        self.signals = try gpa.alloc(Signal, count);
        return self;
    }

    pub fn destroy(self: *Truth) void {
        const gpa = self.gpa;
        if (self.replay) |*replay| replay.deinit();
        self.geometry.deinit();
        gpa.free(self.signals);
        self.log.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn satelliteCount(self: *const Truth) usize {
        return self.geometry.satellites.len;
    }

    pub fn signalCount(self: *const Truth) usize {
        return self.signals.len;
    }

    fn messages(self: *Truth) (error{OutOfMemory} || stage.messages.Failure)!stage.messages.Messages {
        if (self.prepared) |prepared| return prepared;
        const scenario = &self.b.scenario;
        var failure: stage.messages.PreparationFailure = undefined;
        const prepared = stage.messages.Messages.prepare(self.arena.allocator(), scenario.messages, stage.messages.familiesOf(scenario.signals), scenario.start, &failure) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPublication => return error.MessageSet,
        };
        self.prepared = prepared;
        return prepared;
    }

    fn history(self: *Truth) QueryError!*Replay {
        if (self.b.scenario.samples == null) return error.NoSamples;
        if (self.replay == null) self.replay = try Replay.init(self.gpa, self.b, &self.allocation, try self.messages(), &self.log);
        return &self.replay.?;
    }

    fn powerAt(self: *Truth, e: Epoch) void {
        if (self.power_epoch == null or e.ms < self.power_epoch.?.ms) {
            self.power.reset();
            self.next_power = 0;
        }
        self.log.powerTo(&self.power, &self.next_power, e);
        self.power_epoch = e;
    }

    fn maskAt(self: *const Truth, e: Epoch) f64 {
        return self.log.maskAt(self.b.scenario.elevation_mask_rad, channels.replanAt(e, self.span.epochs));
    }

    pub fn submit(self: *Truth, c: bundle.command.Command) SubmitError!void {
        try bundle.command.check(c);
        try self.log.add(self.gpa, c);
        self.full = null;
        switch (c.action) {
            .elevation_mask => if (self.replay) |*replay| replay.invalidate(.{ .ms = c.apply_at_epoch }),
            .noise_floor_dbm_hz, .signal_power => if (self.power_epoch) |e| {
                if (c.apply_at_epoch <= e.ms) self.power_epoch = null;
            },
        }
    }

    pub fn sky(self: *Truth, e: Epoch) error{ OutOfMemory, EpochOutOfRange }!Sky {
        if (e.ms > self.span.epochs) return error.EpochOutOfRange;
        if (self.full_epoch) |previous| if (previous.ms != e.ms) {
            self.full = null;
        };
        const mask = self.maskAt(e);
        const satellites = try self.geometry.all(e, mask);
        const rx = self.geometry.receiver;
        return .{ .pos = rx.pos, .vel = rx.vel, .lla = rx.lla, .mask_rad = mask, .dop = null, .satellites = satellites, .signals = &.{} };
    }

    pub fn visibleCount(self: *Truth, e: Epoch) error{ OutOfMemory, EpochOutOfRange }!u32 {
        const result = try self.sky(e);
        var count: u32 = 0;
        for (result.satellites) |sat| if (sat.record and sat.above_mask and !sat.masked_out) {
            count += 1;
        };
        return count;
    }

    pub fn at(self: *Truth, e: Epoch) QueryError!Sky {
        if (e.ms > self.span.epochs) return error.EpochOutOfRange;
        if (self.full) |cached| if (self.full_epoch.?.ms == e.ms) return cached;
        const replay = try self.history();
        const r = channels.replanAt(e, self.span.epochs);
        try replay.advance(r);
        const states = replay.statesAt(r);
        var out = try self.sky(e);
        self.powerAt(e);
        var n: usize = 0;
        var geometry: sky_values.Geometry = .{};
        for (out.satellites) |sat| {
            var any = false;
            const commanded = self.power.commanded(sat.sat);
            var it = self.system_signals.get(sat.sat.system).iterator();
            while (it.next()) |signal| {
                const state = replay.state(states, sat.sat, signal);
                const held = state == .held and sat.record;
                any = any or held;
                const cn0 = if (held) self.power.cn0(sat.sat, sat.el_rad) + gnss.spec.realizedDb(signal) else 0;
                self.signals[n] = .{ .sat = sat.sat, .signal = signal, .state = state, .commanded = commanded, .cn0_dbhz = cn0 };
                n += 1;
            }
            if (any) geometry.add(sat.az_rad, sat.el_rad);
        }
        out.dop = geometry.dilution();
        out.signals = self.signals[0..n];
        self.full_epoch = e;
        self.full = out;
        return out;
    }

    pub fn inspect(self: *Truth, arena: std.mem.Allocator, query: inspect_values.Query) InspectError!inspect_values.Result {
        if (!query.valid()) return error.InvalidValue;
        if (query.epoch.ms > self.span.epochs) return error.EpochOutOfRange;
        const scenario = &self.b.scenario;
        const sampled = scenario.samples != null;
        const configured = scenario.signals.contains(query.signal);
        const broadcasts = self.allocation.transmits(query.sat, query.signal);
        const mask = self.maskAt(query.epoch);
        const satellite = try self.geometry.target(query.epoch, query.sat, mask);
        self.powerAt(query.epoch);
        var channel: inspect_values.Channel = .{
            .status = if (sampled and configured) .available else .unavailable,
            .reason = if (!sampled) .no_samples else if (!configured) .signal_not_enabled else null,
            .configured = configured,
            .broadcasts = broadcasts,
            .maskedOut = scenario.mask_out.get(query.sat.system).contains(query.sat),
            .commanded = self.power.commanded(query.sat),
            .noiseFloorDbmHz = self.power.noise_floor_dbm_hz,
            .elevationMaskDeg = core.constants.rad2deg(mask),
        };
        if (sampled) {
            const replay = try self.history();
            const r = channels.replanAt(query.epoch, self.span.epochs);
            try replay.advance(r);
            if (configured and satellite != null) {
                const state = replay.state(replay.statesAt(r), query.sat, query.signal);
                channel.state = state;
                if (state == .held) channel.cn0DbHz = if (satellite.?.record) self.power.cn0(query.sat, satellite.?.el_rad) + gnss.spec.realizedDb(query.signal) else 0;
            }
        }
        if (channel.status == .available and channel.state == null) {
            channel.state = if (channel.maskedOut) .masked_out else if (!broadcasts) .not_broadcast else .no_record;
        }
        var result: inspect_values.Result = .{
            .epochMs = .{ .value = @intCast(query.epoch.ms) },
            .endpoint = query.epoch.ms == self.span.epochs,
            .target = .{ .system = query.sat.system, .svid = query.sat.prn(), .signal = query.signal, .family = gnss.spec.get(query.signal).family },
            .channel = channel,
        };
        const t = core.time.atEpoch(self.span.start, query.epoch);
        if (query.includes(.model) or query.includes(.navigation)) {
            var local: shared.track.provider.Track = .{};
            const provider = self.geometry.provider(query.sat) orelse fallback: {
                _ = local.advanceTo(self.b, query.sat, t);
                break :fallback &local;
            };
            const state = if (query.includes(.model) and provider.current != null) provider.stateAt(t) else null;
            const projected = inspect_values.model.project(self.b, provider, state, query.sat, query.signal, t, .{ .model = query.includes(.model), .navigation = query.includes(.navigation) });
            result.model = projected.model;
            result.navigation = projected.navigation;
        }
        if (query.includes(.messages) or query.includes(.service)) {
            const r = channels.replanAt(query.epoch, self.span.epochs);
            const view = if (sampled and query.includes(.messages)) try self.replay.?.viewAt(query.signal, core.time.atEpoch(self.span.start, r)) else null;
            const window = if (view) |v| v.window else stage.sequence.Window{ .from = self.span.start, .until = self.span.start };
            const end = core.time.atEpoch(self.span.start, .{ .ms = self.span.epochs });
            const until = if (end.lessThan(window.until)) end else window.until;
            const prepared = if (sampled) self.prepared.? else stage.messages.Messages{};
            const projected = try inspect_values.messages.project(arena, self.b, &self.allocation, prepared, if (view) |v| v.forSignal(query.signal) else null, window.from, until, t, query.sat, query.signal, sampled, .{ .messages = query.includes(.messages), .service = query.includes(.service) });
            result.messages = projected.messages;
            result.service = projected.service;
        }
        return result;
    }
};
