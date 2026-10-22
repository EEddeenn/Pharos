const std = @import("std");
const time = @import("domain/time/gps");
const command_log = @import("simulation/state/commands");
const command = @import("simulation/model/command");
const signal_catalog = @import("domain/signals/catalog");
const display_model = @import("phb/model/display");
const tracking = @import("simulation/tracking/track");
const projection = @import("products/obs/inspect/project");
const sequence = @import("simulation/state/sequence");
const message_projection = @import("products/obs/inspect/messages");
const prepared_scenario = @import("simulation/model/prepared_scenario");
const gnss_types = @import("domain/gnss_types");
const coordinates = @import("domain/earth/coordinates");
const channels = @import("simulation/state/channels");
const inspect_values = @import("products/obs/inspect/query");
const sky_values = @import("products/obs/truth/sky");
const angles = @import("base/math/angles");

const Samples = @import("simulation/model/config").Samples;
const Replay = @import("products/obs/truth/replay").Replay;

const Epoch = time.Epoch;

pub const CreateError = error{OutOfMemory};
pub const QueryError = error{ OutOfMemory, EpochOutOfRange, NoSamples };
pub const SubmitError = error{ OutOfMemory, InvalidValue };
pub const InspectError = error{ OutOfMemory, EpochOutOfRange, InvalidValue };

pub const Satellite = sky_values.Satellite;
pub const Dop = sky_values.Dop;

pub const Signal = struct {
    sat: gnss_types.SatId,
    signal: gnss_types.Signal,
    state: channels.State,
    commanded: bool,
    cn0_dbhz: f64,
};

pub const Sky = struct {
    pos: coordinates.Ecef,
    vel: coordinates.Ecef,
    lla: coordinates.Lla,
    mask_rad: f64,
    dop: ?Dop,
    satellites: []const Satellite,
    signals: []const Signal,
};

pub const Truth = struct {
    gpa: std.mem.Allocator,
    b: *const prepared_scenario.PreparedScenario,
    playback: command_log.PowerPlayback,
    log: command_log.Log = .{},
    geometry: sky_values.Sky,
    replay: ?Replay = null,
    signals: []Signal,
    system_signals: std.EnumArray(gnss_types.System, std.EnumSet(gnss_types.Signal)),
    full: ?struct { epoch: Epoch, result: Sky } = null,

    pub fn create(gpa: std.mem.Allocator, b: *const prepared_scenario.PreparedScenario) CreateError!*Truth {
        const self = try gpa.create(Truth);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .b = b,
            .playback = .init(b.config.power),
            .geometry = undefined,
            .signals = &.{},
            .system_signals = .initFill(.empty),
        };
        var it = b.config.signals.iterator();
        while (it.next()) |signal| self.system_signals.getPtr(signal.system()).insert(signal);
        self.geometry = try sky_values.Sky.init(gpa, .{
            .window = .{
                .ephemerides = .{ .flight_plan = &b.flight_plan, .precise = b.precise, .phase_centres = &b.phase_centres },
                .trajectory = &b.trajectory,
                .start = b.config.start,
            },
            .signals = b.config.signals,
            .mask_out = &b.config.mask_out,
        }, &b.payload);
        errdefer self.geometry.deinit();
        var count: usize = 0;
        if (b.config.samples != null) {
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
        gpa.destroy(self);
    }

    pub fn satelliteCount(self: *const Truth) usize {
        return self.geometry.satellites.len;
    }

    pub fn signalCount(self: *const Truth) usize {
        return self.signals.len;
    }

    pub fn submit(self: *Truth, c: command.Command) SubmitError!void {
        try command.check(c);
        try self.log.add(self.gpa, c);
        self.full = null;
        switch (c.action) {
            .elevation_mask => if (self.replay) |*replay| replay.invalidate(.{ .ms = c.apply_at_epoch }),
            .noise_floor_dbm_hz, .signal_power => self.playback.invalidate(.{ .ms = c.apply_at_epoch }),
        }
    }

    pub fn sky(self: *Truth, e: Epoch) error{ OutOfMemory, EpochOutOfRange }!Sky {
        if (e.ms > self.b.epochs()) return error.EpochOutOfRange;
        return self.skyAt(e);
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
        if (e.ms > self.b.epochs()) return error.EpochOutOfRange;
        if (self.full) |cached| if (cached.epoch.ms == e.ms) return cached.result;
        const replay = try self.history(self.b.config.samples orelse return error.NoSamples);
        const r = channels.replanAt(e, self.b.epochs());
        try replay.advance(r);
        const states = replay.statesAt(r);
        var out = try self.skyAt(e);
        self.playback.advance(&self.log, e);
        var n: usize = 0;
        var geometry: sky_values.Geometry = .{};
        for (out.satellites) |sat| {
            var any = false;
            const commanded = self.playback.state.commanded(sat.sat);
            var it = self.system_signals.get(sat.sat.system).iterator();
            while (it.next()) |signal| {
                const state = replay.state(states, sat.sat, signal);
                const held = state == .held and sat.record;
                any = any or held;
                const cn0 = if (held) self.playback.state.cn0(sat.sat, sat.el_rad) + signal_catalog.realizedDb(signal) else 0;
                self.signals[n] = .{ .sat = sat.sat, .signal = signal, .state = state, .commanded = commanded, .cn0_dbhz = cn0 };
                n += 1;
            }
            if (any) geometry.add(sat.az_rad, sat.el_rad);
        }
        out.dop = geometry.dilution();
        out.signals = self.signals[0..n];
        self.full = .{ .epoch = e, .result = out };
        return out;
    }

    pub fn inspect(self: *Truth, arena: std.mem.Allocator, display: *const display_model.Display, query: inspect_values.Query) InspectError!inspect_values.Result {
        if (!query.valid()) return error.InvalidValue;
        if (query.epoch.ms > self.b.epochs()) return error.EpochOutOfRange;
        const scenario = &self.b.config;
        const sampled = scenario.samples != null;
        const configured = scenario.signals.contains(query.signal);
        const carrier = self.b.payload.familyOf(query.sat, query.signal);
        const broadcasts = carrier != null;
        // A signal the satellite does not transmit is shown with the family its signal names.
        const family = carrier orelse signal_catalog.get(query.signal).family;
        const mask = self.maskAt(query.epoch);
        const satellite = try self.geometry.target(query.epoch, query.sat, mask);
        self.playback.advance(&self.log, query.epoch);
        var channel: inspect_values.Channel = .{
            .status = if (sampled and configured) .available else .unavailable,
            .reason = if (!sampled) .no_samples else if (!configured) .signal_not_enabled else null,
            .configured = configured,
            .broadcasts = broadcasts,
            .maskedOut = scenario.mask_out.get(query.sat.system).contains(query.sat),
            .commanded = self.playback.state.commanded(query.sat),
            .noiseFloorDbmHz = self.playback.state.noise_floor_dbm_hz,
            .elevationMaskDeg = angles.rad2deg(mask),
        };
        if (scenario.samples) |samples| {
            const replay = try self.history(samples);
            const r = channels.replanAt(query.epoch, self.b.epochs());
            try replay.advance(r);
            if (configured and satellite != null) {
                const state = replay.state(replay.statesAt(r), query.sat, query.signal);
                channel.state = state;
                if (state == .held) channel.cn0DbHz = if (satellite.?.record) self.playback.state.cn0(query.sat, satellite.?.el_rad) + signal_catalog.realizedDb(query.signal) else 0;
            }
        }
        if (channel.status == .available and channel.state == null) {
            channel.state = if (channel.maskedOut) .masked_out else if (!broadcasts) .not_broadcast else .no_record;
        }
        var result: inspect_values.Result = .{
            .epochMs = .{ .value = @intCast(query.epoch.ms) },
            .endpoint = query.epoch.ms == self.b.epochs(),
            .target = .{ .system = query.sat.system, .svid = query.sat.prn(), .signal = query.signal, .family = family },
            .channel = channel,
        };
        const t = time.atEpoch(self.b.config.start, query.epoch);
        if (query.includes(.model) or query.includes(.navigation)) {
            var local: tracking.Track = .{};
            const provider = self.geometry.provider(query.sat) orelse fallback: {
                _ = local.advanceTo(.{ .flight_plan = &self.b.flight_plan, .precise = self.b.precise, .phase_centres = &self.b.phase_centres }, query.sat, t);
                break :fallback &local;
            };
            if (query.includes(.model)) result.model = projection.model(.{ .flight_plan = &self.b.flight_plan, .ionosphere = &scenario.ionosphere }, provider, query.sat, query.signal, t);
            if (query.includes(.navigation)) result.navigation = projection.navigation(display, if (provider.current) |*current| &current.selection else null, query.signal);
        }
        if (query.includes(.messages) or query.includes(.service)) {
            const publications = if (self.b.messages) |*messages| &messages.publications else null;
            const r = channels.replanAt(query.epoch, self.b.epochs());
            const window = if (publications != null and query.includes(.messages) and self.b.payload.families(scenario.signals).contains(family))
                sequence.inspectionWindowAt(self.b.config.start, self.b.flight_plan.leap, family.system(), time.atEpoch(self.b.config.start, r))
            else
                sequence.Window{ .from = self.b.config.start, .until = self.b.config.start };
            const end = time.atEpoch(self.b.config.start, .{ .ms = self.b.epochs() });
            const until = if (end.lessThan(window.until)) end else window.until;
            const target: message_projection.QueryTarget = .{ .time = t, .sat = query.sat, .signal = query.signal, .family = family };
            if (query.includes(.messages)) result.messages = try message_projection.message(arena, .{
                .start = scenario.start,
                .signals = scenario.signals,
                .flight_plan = &self.b.flight_plan,
                .payload = &self.b.payload,
                .publications = publications,
            }, display, target, .{ .from = window.from, .until = until });
            if (query.includes(.service)) result.service = message_projection.service(.{
                .plan = self.b.services,
                .has = scenario.has,
                .ppp_b2b = scenario.ppp_b2b,
                .signals = scenario.signals,
                .publications = publications,
            }, target);
        }
        return result;
    }

    fn history(self: *Truth, samples: Samples) error{OutOfMemory}!*Replay {
        if (self.replay == null) self.replay = try Replay.init(self.gpa, .{
            .ephemerides = .{ .flight_plan = &self.b.flight_plan, .precise = self.b.precise, .phase_centres = &self.b.phase_centres },
            .trajectory = &self.b.trajectory,
            .start = self.b.config.start,
            .signals = self.b.config.signals,
            .mask_out = self.b.config.mask_out,
            .samples = samples,
            .elevation_mask_rad = self.b.config.elevation_mask_rad,
        }, &self.b.payload, &self.log);
        return &self.replay.?;
    }

    fn maskAt(self: *const Truth, e: Epoch) f64 {
        return self.log.maskAt(self.b.config.elevation_mask_rad, channels.replanAt(e, self.b.epochs()));
    }

    fn skyAt(self: *Truth, e: Epoch) error{OutOfMemory}!Sky {
        if (self.full) |cached| if (cached.epoch.ms != e.ms) {
            self.full = null;
        };
        const mask = self.maskAt(e);
        const satellites = try self.geometry.all(e, mask);
        const rx = self.geometry.receiver_cache.?.frame;
        return .{ .pos = rx.pos, .vel = rx.vel, .lla = rx.lla, .mask_rad = mask, .dop = null, .satellites = satellites, .signals = &.{} };
    }
};
