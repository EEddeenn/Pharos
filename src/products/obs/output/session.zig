const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const civil = @import("domain/time/civil");
const time = @import("domain/time/gps");
const receiver = @import("simulation/geometry/receiver");
const command_model = @import("simulation/model/command");
const commands = @import("simulation/state/commands");
const observe = @import("products/obs/observation");
const rinex = @import("products/obs/output/rinex");
const position = @import("products/obs/output/position");

const Trajectory = @import("domain/trajectory/trajectory").Trajectory;
const PreparedScenario = @import("simulation/model/prepared_scenario").PreparedScenario;
const FlightPlan = @import("simulation/model/flight_plan").FlightPlan;
const PositionFormat = @import("simulation/model/config").PositionFormat;
const IonosphereInfo = @import("simulation/state/ionosphere").Info;
const replanAt = @import("simulation/state/channels").replanAt;

const Io = std.Io;

pub const CreateError = error{ OutOfMemory, NoSuchOutput };
pub const SubmitError = error{ OutOfMemory, InvalidValue, EpochPassed, CommandsNotSupported };
pub const RangeError = error{ Begun, EpochOutOfRange, EmptyRange, NoEpochs };
pub const PullError = error{InvalidBatchSize};
pub const EpochRange = struct { first: u64, end: u64 };
pub const OutputKind = enum(u8) {
    observation = 0,
    position = 1,

    pub const words: std.EnumArray(OutputKind, []const u8) = .init(.{ .observation = "observation", .position = "position" });
};
pub const OutputRequest = union(OutputKind) { observation: Created, position };
pub const max_batch_epochs: u32 = 64;
pub const Summary = struct { kind: OutputKind, first_ms: u64, last_ms: u64, epochs: u64, interval_ms: u32, tracked: ?usize };
pub const Batch = struct { bytes: []const u8, completed_epochs: u64, generated_through: ?u64, end: bool };

pub const Created = struct {
    unix_s: i64,

    pub const min: Created = .{ .unix_s = 0 };
    pub const max: Created = .{ .unix_s = civil.daysFromCivil(civil.last_year + 1, 1, 1) * 86_400 - 1 };

    pub fn fromUnixSeconds(s: i64) ?Created {
        return if (s >= min.unix_s and s <= max.unix_s) .{ .unix_s = s } else null;
    }

    pub fn fromWallClock(io: Io, read_s: *i64) ?Created {
        read_s.* = Io.Clock.real.now(io).toSeconds();
        return fromUnixSeconds(read_s.*);
    }
};

const Sampler = struct {
    start: time.GpsTime,
    interval_ms: u32,
    last_epoch_ms: u64,
    end_index: u64,
    first_index: u64 = 0,
    next_index: u64 = 0,

    fn init(start: time.GpsTime, epochs: u64, interval_ms: u32) Sampler {
        return .{ .start = start, .interval_ms = interval_ms, .last_epoch_ms = epochs, .end_index = epochs / interval_ms + 1 };
    }

    fn next(self: *Sampler) ?time.Epoch {
        if (self.next_index >= self.end_index) return null;
        const epoch: time.Epoch = .{ .ms = self.next_index * self.interval_ms };
        self.next_index += 1;
        return epoch;
    }

    fn generatedThrough(self: *const Sampler) ?u64 {
        return if (self.next_index == self.first_index) null else (self.next_index - 1) * self.interval_ms;
    }

    fn range(self: *Sampler, requested: EpochRange) error{ EpochOutOfRange, EmptyRange, NoEpochs }!void {
        if (requested.first >= requested.end) return error.EmptyRange;
        if (requested.end > self.last_epoch_ms + 1) return error.EpochOutOfRange;
        const first = self.indexAtOrAfter(requested.first);
        const end = self.indexAtOrAfter(requested.end);
        if (first >= end) return error.NoEpochs;
        self.first_index = first;
        self.end_index = end;
        self.next_index = first;
    }

    fn indexAtOrAfter(self: *const Sampler, ms: u64) u64 {
        return ms / self.interval_ms + @intFromBool(ms % self.interval_ms != 0);
    }

    fn firstMs(self: *const Sampler) u64 {
        return self.first_index * self.interval_ms;
    }

    fn lastMs(self: *const Sampler) u64 {
        return (self.end_index - 1) * self.interval_ms;
    }
};

const Observation = struct {
    cursor: *observe.ObservationCursor,
    trajectory: *const Trajectory,
    flight_plan: *const FlightPlan,
    elevation_mask_rad: f64,
    layout: rinex.Layout,
    created: civil.Utc,
    glonass_freq: [24]?gnss_types.FreqId = @splat(null),
    power: commands.PowerPlayback,
    commands: commands.Log = .{},
};

const Content = union(OutputKind) {
    observation: Observation,
    position: struct { trajectory: *const Trajectory, format: PositionFormat },
};

pub const File = struct {
    gpa: std.mem.Allocator,
    sampler: Sampler,
    content: Content,
    buffer: []u8,
    stage: enum { header, epochs, done } = .header,

    pub fn create(gpa: std.mem.Allocator, scenario: *const PreparedScenario, request: OutputRequest) CreateError!*File {
        const config = &scenario.config;
        const interval_ms = switch (request) {
            .observation => (config.observation orelse return error.NoSuchOutput).interval_ms,
            .position => (config.position orelse return error.NoSuchOutput).interval_ms,
        };
        const content: Content = switch (request) {
            .observation => |created| .{ .observation = .{
                .cursor = try observe.ObservationCursor.create(gpa, scenario),
                .trajectory = &scenario.trajectory,
                .flight_plan = &scenario.flight_plan,
                .elevation_mask_rad = config.elevation_mask_rad,
                .layout = .init(config.signals),
                .created = civil.fromUnix(created.unix_s),
                .power = .init(config.power),
            } },
            .position => .{ .position = .{ .trajectory = &scenario.trajectory, .format = config.position.?.format } },
        };
        errdefer switch (content) {
            .observation => |observation| observation.cursor.destroy(),
            .position => {},
        };
        const epoch_bytes = switch (content) {
            .observation => |observation| observation.layout.epochBytes(observation.cursor.tracked()) + if (observation.layout.listed(.glo)) rinex.max_glonass_update_bytes else @as(usize, 0),
            .position => 1024,
        };
        const buffer = try gpa.alloc(u8, 16 * 1024 + max_batch_epochs * epoch_bytes + 1024);
        errdefer gpa.free(buffer);
        const self = try gpa.create(File);
        self.* = .{ .gpa = gpa, .sampler = .init(config.start, scenario.epochs(), interval_ms), .content = content, .buffer = buffer };
        return self;
    }

    pub fn destroy(self: *File) void {
        switch (self.content) {
            .observation => |*observation| {
                observation.commands.deinit(self.gpa);
                observation.cursor.destroy();
            },
            .position => {},
        }
        self.gpa.free(self.buffer);
        self.gpa.destroy(self);
    }

    pub fn setRange(self: *File, requested: EpochRange) RangeError!void {
        if (self.stage != .header) return error.Begun;
        try self.sampler.range(requested);
    }

    pub fn fullRange(self: *const File) EpochRange {
        return .{ .first = 0, .end = self.sampler.last_epoch_ms + 1 };
    }

    pub fn summary(self: *const File) Summary {
        return .{
            .kind = std.meta.activeTag(self.content),
            .first_ms = self.sampler.firstMs(),
            .last_ms = self.sampler.lastMs(),
            .epochs = self.sampler.end_index - self.sampler.first_index,
            .interval_ms = self.sampler.interval_ms,
            .tracked = switch (self.content) {
                .observation => |observation| observation.cursor.tracked(),
                .position => null,
            },
        };
    }

    pub fn ionosphere(self: *const File) ?IonosphereInfo {
        return switch (self.content) {
            .observation => |observation| observation.cursor.ionosphere_info,
            .position => null,
        };
    }

    pub fn submit(self: *File, command: command_model.Command) SubmitError!void {
        if (self.content == .position) return error.CommandsNotSupported;
        try command_model.check(command);
        if (self.sampler.generatedThrough()) |epoch| if (command.apply_at_epoch <= epoch) return error.EpochPassed;
        try self.content.observation.commands.add(self.gpa, command);
    }

    /// The batch bytes borrow this file's buffer until its next pull or destruction.
    pub fn pull(self: *File, max_epochs: u32) PullError!Batch {
        if (max_epochs == 0 or max_epochs > max_batch_epochs) return error.InvalidBatchSize;
        var writer: Io.Writer = .fixed(self.buffer);
        if (self.stage == .header) {
            self.writeHeader(&writer) catch unreachable;
            self.stage = .epochs;
        }
        var count: u32 = 0;
        while (self.stage == .epochs and count < max_epochs) : (count += 1) {
            const epoch = self.sampler.next() orelse break;
            switch (self.content) {
                .observation => |*observation| {
                    observation.power.advance(&observation.commands, epoch);
                    const mask = observation.commands.maskAt(observation.elevation_mask_rad, replanAt(epoch, self.sampler.last_epoch_ms));
                    const observed = observe.sampleEpoch(observation.cursor, epoch, mask, &observation.power.state);
                    if (observation.layout.listed(.glo)) {
                        const freq = glonassFrequencies(observation.flight_plan, self.sampler.start, epoch);
                        if (!std.meta.eql(freq, observation.glonass_freq)) {
                            rinex.rinexGlonassUpdate(&writer, observed.t, freq) catch unreachable;
                            observation.glonass_freq = freq;
                        }
                    }
                    rinex.rinexEpoch(&writer, observed, &observation.layout) catch unreachable;
                },
                .position => |value| {
                    const rx = receiver.atMs(value.trajectory, epoch.ms);
                    position.positionEpoch(&writer, value.format, time.atEpoch(self.sampler.start, epoch), rx.pos, rx.lla) catch unreachable;
                },
            }
        }
        if (self.stage == .epochs and self.sampler.next_index == self.sampler.end_index) {
            switch (self.content) {
                .observation => {},
                .position => |value| position.positionFooter(&writer, value.format) catch unreachable,
            }
            self.stage = .done;
        }
        return .{
            .bytes = writer.buffered(),
            .completed_epochs = self.sampler.next_index - self.sampler.first_index,
            .generated_through = self.sampler.generatedThrough(),
            .end = self.stage == .done,
        };
    }

    fn writeHeader(self: *File, writer: *Io.Writer) Io.Writer.Error!void {
        switch (self.content) {
            .observation => |*observation| {
                const first_ms = self.sampler.firstMs();
                observation.glonass_freq = glonassFrequencies(observation.flight_plan, self.sampler.start, .{ .ms = first_ms });
                try rinex.rinexHeader(writer, .{
                    .approx_pos = receiver.atMs(observation.trajectory, first_ms).pos,
                    .layout = observation.layout,
                    .interval_ms = self.sampler.interval_ms,
                    .glonass_freq = observation.glonass_freq,
                    .created = observation.created,
                    .first = time.atEpoch(self.sampler.start, .{ .ms = first_ms }),
                    .last = time.atEpoch(self.sampler.start, .{ .ms = self.sampler.lastMs() }),
                    .moving = observation.trajectory.moves(@as(f64, @floatFromInt(self.sampler.last_epoch_ms)) / 1000.0),
                    .leap = observation.flight_plan.leap,
                });
            },
            .position => |value| try position.positionHeader(writer, value.format),
        }
    }
};

/// Why a file could not be made, in the words of a sentence.
pub fn reason(e: CreateError) []const u8 {
    return switch (e) {
        error.OutOfMemory => "out of memory",
        error.NoSuchOutput => "the bundle declares none",
    };
}

fn glonassFrequencies(flight_plan: *const FlightPlan, start: time.GpsTime, epoch: time.Epoch) [24]?gnss_types.FreqId {
    var out: [24]?gnss_types.FreqId = @splat(null);
    const t = time.atEpoch(start, epoch);
    var satellites = gnss_types.System.glo.satellites();
    while (satellites.next()) |sat| {
        if (flight_plan.bindingAt(sat, t)) |binding| out[sat.index] = binding.freq;
    }
    return out;
}
