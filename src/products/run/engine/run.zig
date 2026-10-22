const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const configuration = @import("simulation/model/config");
const sampling = @import("simulation/model/sampling");
const flight = @import("simulation/model/flight_plan");
const prepared_scenario = @import("simulation/model/prepared_scenario");
const binding = @import("simulation/tracking/binding");
const ionosphere_state = @import("simulation/state/ionosphere");
const engine_channels = @import("products/run/engine/channels");
const geometry = @import("products/run/engine/geometry");
const events = @import("products/run/engine/events");
const commands = @import("products/run/engine/commands");
const workers = @import("products/run/engine/workers");
const noise = @import("products/run/synthesis/noise");
const kernel = @import("products/run/synthesis/kernel");
const gain = @import("products/run/synthesis/gain");

const PowerPlayback = @import("simulation/state/commands").PowerPlayback;
const replan_epochs = @import("simulation/state/channels").replan_epochs;

const Io = std.Io;
const Epoch = time.Epoch;
const GpsTime = time.GpsTime;

pub const NoiseMode = noise.Mode;
pub const GainSetting = gain.Setting;
pub const GainStatus = gain.Status;
pub const GenerationError = engine_channels.Error || error{OutOfMemory};
pub const CreateError = error{ OutOfMemory, ThreadSpawnFailed, NoSamples };
pub const PullError = error{ InvalidBatchSize, BufferTooSmall };
pub const SeekError = GenerationError || error{ EpochOutOfRange, AdaptiveGain, CommandsApplied };

pub const Options = struct { seed: u64 = 0, workers: u32 = 0, noise: NoiseMode = .counter, gain: GainSetting = .adaptive };
pub const DumpWriters = struct { rows: ?*Io.Writer = null, plan: ?*Io.Writer = null, params: ?*Io.Writer = null };

pub const Info = struct {
    samples: configuration.Samples,
    samples_per_epoch: u32,
    bytes_per_epoch: usize,
    span: prepared_scenario.Span,
    workers: u32,
    seed: u64,
    noise: NoiseMode,
};

pub const Status = struct {
    epoch: Epoch,
    entry_epoch: Epoch,
    total_bytes: u64,
    total_clipped: u64,
    gain: GainStatus,
    failure: ?GenerationError,
};

pub const Block = struct {
    epoch_first: Epoch,
    epochs: u32 = 0,
    bytes: usize = 0,
    clipped: u64 = 0,
    applied: []const commands.Applied = &.{},
    failure: ?GenerationError = null,
};

const Reasoned = CreateError || PullError || SeekError;

pub fn reason(e: Reasoned) []const u8 {
    return switch (e) {
        error.ThreadSpawnFailed => "a worker thread could not be started",
        error.NoSamples => "the scenario has no samples output",
        error.InvalidBatchSize => "a pull must request at least one epoch",
        error.BufferTooSmall => "the output buffer cannot hold an epoch",
        error.EpochOutOfRange => "the epoch lies beyond the end of the run",
        error.AdaptiveGain => "the adaptive AGC depends on every epoch before the target",
        error.CommandsApplied => "the seek starts the run over, which would drop the commands it has applied",
        error.OutOfMemory => "out of memory",
        error.Internal => "signal parameters are outside the supported calculation range",
    };
}

comptime {
    std.debug.assert(replan_epochs % geometry.block_epochs == 0);
}

const window_epochs = @min(geometry.block_epochs, gain.evaluation_epochs);

pub const Run = struct {
    gpa: std.mem.Allocator,
    threaded: Io.Threaded,
    span: prepared_scenario.Span,
    pool: ?*workers.Pool(Run),
    scratch: []kernel.Scratch,
    geometry: *geometry.Geometry,
    channels: *engine_channels.Channels,
    power: PowerPlayback,
    blocks_produced: u64 = 0,
    kernel_config: kernel.Config,
    sub_tiles: u32,
    clipped: std.atomic.Value(u64) = .init(0),
    ready: [window_epochs]std.atomic.Value(bool) = undefined,
    epoch: Epoch = .zero,
    gain: gain.Gain,
    total_clipped: u64 = 0,
    total_bytes: u64 = 0,
    failure: ?GenerationError = null,
    events: events.Ring = .{},
    commands: commands.Queue = .{},
    applied: [commands.capacity]commands.Applied = undefined,
    seek_to: ?Epoch = null,

    const SampleJob = struct { epochs: u32, first: Epoch, gain: f32, out: []u8 };
    pub const Job = union(enum) { correct: u32, produce: struct { rows: ?geometry.Segment = null, samples: ?SampleJob = null } };

    pub fn create(gpa: std.mem.Allocator, scenario: *const prepared_scenario.PreparedScenario, options: Options, dumps: DumpWriters) CreateError!*Run {
        const config = &scenario.config;
        const samples = config.samples orelse return error.NoSamples;
        const spe = samples.sample_rate.samplesPerEpoch();
        const worker_count = if (options.workers == 0) @as(u32, @intCast(std.Thread.getCpuCount() catch 1)) else options.workers;
        const sub_tile = kernel.subTileFor(spe);
        const kernel_config: kernel.Config = .{ .samples_per_epoch = spe, .sub_tile_len = sub_tile, .format = samples.format, .noise = options.noise, .seed = options.seed };
        const ephemerides: binding.Inputs = .{ .flight_plan = &scenario.flight_plan, .precise = scenario.precise, .phase_centres = &scenario.phase_centres };
        const geom = try geometry.Geometry.create(gpa, .{
            .window = .{ .ephemerides = ephemerides, .trajectory = &scenario.trajectory, .start = config.start },
            .signals = config.signals,
            .mask_out = config.mask_out,
            .ionosphere = &config.ionosphere.ready,
            .payload = &scenario.payload,
        }, dumps.rows);
        errdefer geom.destroy();
        var satellites: [flight.satellite_count]gnss_types.SatId = undefined;
        const sats = satellites[0..geom.observation.entries.len];
        for (geom.observation.entries, sats) |entry, *sat| sat.* = entry.sat;
        const channels = try engine_channels.Channels.create(gpa, .{
            .ephemerides = ephemerides,
            .prepared = &scenario.messages.?,
            .service_plan = scenario.services,
            .payload = &scenario.payload,
            .trajectory = &scenario.trajectory,
            .start = config.start,
            .signals = config.signals,
            .elevation_mask_rad = config.elevation_mask_rad,
            .has = config.has,
            .ppp_b2b = config.ppp_b2b,
            .samples = samples,
            .window_epochs = window_epochs,
        }, sats, geom.ionosphere.models.get(.bds), .{ .params = dumps.params, .plan = dumps.plan });
        errdefer channels.destroy();
        const self = try gpa.create(Run);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = .init_single_threaded,
            .span = scenario.span(),
            .pool = null,
            .scratch = &.{},
            .geometry = geom,
            .channels = channels,
            .power = .init(config.power),
            .gain = .of(options.gain),
            .kernel_config = kernel_config,
            .sub_tiles = kernel.subTiles(kernel_config),
        };
        if (worker_count > 1) self.pool = workers.Pool(Run).create(gpa, self.threaded.io(), self, worker_count - 1) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ThreadSpawnFailed,
        };
        errdefer if (self.pool) |pool| pool.destroy();
        self.scratch = try allocScratch(gpa, worker_count, sub_tile, kernel.expandSlack(channels.maxSamplesPerEntry()));
        self.begin();
        return self;
    }

    pub fn destroy(self: *Run) void {
        if (self.pool) |p| p.destroy();
        self.channels.destroy();
        self.geometry.destroy();
        freeScratch(self.gpa, self.scratch);
        self.gpa.destroy(self);
    }

    pub fn info(self: *const Run) Info {
        return .{
            .samples = .{ .format = self.kernel_config.format, .sample_rate = sampling.SampleRate.fromKhz(self.kernel_config.samples_per_epoch), .center = self.channels.active.center },
            .samples_per_epoch = self.kernel_config.samples_per_epoch,
            .bytes_per_epoch = self.bytesPerEpoch(),
            .span = self.span,
            .workers = @intCast(self.scratch.len),
            .seed = self.kernel_config.seed,
            .noise = self.kernel_config.noise,
        };
    }

    pub fn status(self: *const Run) Status {
        return .{ .epoch = self.epoch, .entry_epoch = self.entryEpoch(), .total_bytes = self.total_bytes, .total_clipped = self.total_clipped, .gain = self.gain.status(), .failure = self.failure };
    }

    pub fn ionosphere(self: *const Run) ionosphere_state.Info {
        return self.geometry.ionosphere_info;
    }

    pub fn generatedSignals(self: *const Run) std.EnumSet(gnss_types.Signal) {
        return self.channels.active.generated;
    }

    pub fn entryEpoch(self: *const Run) Epoch {
        return self.channels.active.entry_epoch;
    }

    pub fn entryTime(self: *const Run) GpsTime {
        return time.atEpoch(self.span.start, self.entryEpoch());
    }

    pub fn submit(self: *Run, c: commands.Command) commands.SubmitError!void {
        return self.commands.submit(c, self.epoch);
    }

    pub fn nextEvent(self: *Run) ?events.Event {
        return self.events.next();
    }

    pub fn eventsDropped(self: *const Run) u32 {
        return self.events.dropped;
    }

    pub fn pull(self: *Run, out: []u8, max_epochs: u32) PullError!Block {
        if (max_epochs == 0) return error.InvalidBatchSize;
        const bpe = self.bytesPerEpoch();
        if (self.failure) |e| return .{ .epoch_first = self.epoch, .failure = e };
        const left = self.span.epochs - self.epoch.ms;
        if (left == 0) return .{ .epoch_first = self.epoch };
        const fit = @min(out.len / bpe, max_epochs);
        if (fit == 0) return error.BufferTooSmall;
        const epochs = @min(left, fit);
        const first = self.epoch;
        var produced: u32 = 0;
        var clipped: u64 = 0;
        var applied_count: usize = 0;
        const failed: ?GenerationError = while (produced < epochs) {
            const count = self.step(epochs - produced, out[produced * bpe ..], &applied_count) catch |e| break e;
            const window_sum = self.clipped.swap(0, .monotonic);
            clipped += window_sum;
            self.total_clipped += window_sum;
            self.total_bytes += count * bpe;
            produced += count;
            const components = @as(u64, count) * self.kernel_config.samples_per_epoch * 2;
            if (self.gain.account(self.epoch, window_sum, components)) |adj| self.events.push(.{ .agc = adj });
        } else null;
        return .{
            .epoch_first = first,
            .epochs = produced,
            .bytes = produced * bpe,
            .clipped = clipped,
            .applied = self.applied[0..applied_count],
            .failure = failed,
        };
    }

    pub fn seek(self: *Run, target_epoch: Epoch) SeekError!void {
        if (self.gain == .adaptive) return error.AdaptiveGain;
        if (target_epoch.ms > self.span.epochs) return error.EpochOutOfRange;
        self.seek_to = target_epoch;
        defer self.seek_to = null;
        if (target_epoch.ms < self.epoch.ms or self.failure != null) {
            if (self.commands.taken != 0) return error.CommandsApplied;
            self.restart();
        }
        var applied_count: usize = 0;
        self.events.retainSwitches(target_epoch);
        while (self.epoch.ms < target_epoch.ms) : (self.events.retainSwitches(target_epoch)) {
            _ = try self.step(target_epoch.ms - self.epoch.ms, null, &applied_count);
        }
        self.channels.active.enter(target_epoch, &self.events);
        self.total_clipped = 0;
        self.total_bytes = 0;
    }

    pub fn runTask(self: *Run, worker_id: usize, job: Job, index: u32) void {
        const work = switch (job) {
            .correct => return self.geometry.observation.correct(index),
            .produce => |work| work,
        };
        const epochs = if (work.samples) |samples| samples.epochs else 0;
        if (index < epochs) {
            self.channels.deriveEpoch(index, &self.power.state);
            return self.ready[index].store(true, .release);
        }
        const tiles = self.sub_tiles;
        const tile = index - epochs;
        if (tile >= epochs * tiles) return self.geometry.produceRows(work.rows.?.first.plus(tile - epochs * tiles));
        const samples = work.samples.?;
        const epoch = tile / tiles;
        while (!self.ready[epoch].load(.acquire)) std.atomic.spinLoopHint();
        const bpe = self.bytesPerEpoch();
        const slot = samples.out[epoch * bpe ..][0..bpe];
        _ = self.clipped.fetchAdd(kernel.synthSubTile(self.kernel_config, &self.channels.codes, self.channels.epochRows(epoch), samples.first.plus(epoch), tile % tiles, samples.gain, &self.scratch[worker_id], slot), .monotonic);
    }

    fn begin(self: *Run) void {
        self.produceBlock(0, null);
        _ = self.channels.plan(.zero, 1, self.geometry, &self.events);
    }

    fn bytesPerEpoch(self: *const Run) usize {
        return self.kernel_config.format.bytesFor(self.kernel_config.samples_per_epoch);
    }

    fn allocScratch(gpa: std.mem.Allocator, slots: usize, sub_tile_len: u32, slack: u32) error{OutOfMemory}![]kernel.Scratch {
        const scratch = try gpa.alloc(kernel.Scratch, slots);
        errdefer gpa.free(scratch);
        var made: usize = 0;
        errdefer for (scratch[0..made]) |*s| s.deinit(gpa);
        for (scratch) |*s| {
            s.* = try kernel.Scratch.init(gpa, sub_tile_len, slack);
            made += 1;
        }
        return scratch;
    }

    fn freeScratch(gpa: std.mem.Allocator, scratch: []kernel.Scratch) void {
        for (scratch) |*s| s.deinit(gpa);
        gpa.free(scratch);
    }

    fn restart(self: *Run) void {
        self.geometry.reset();
        self.channels.reset();
        self.power.reset();
        self.events.truncate(0);
        self.epoch = .zero;
        self.blocks_produced = 0;
        self.failure = null;
        self.begin();
    }

    fn step(self: *Run, limit_epochs: u64, out: ?[]u8, applied_count: *usize) GenerationError!u32 {
        const first = self.epoch;
        applied_count.* += self.applyDue(first, applied_count.*) catch |e| return self.fail(e);
        const count = self.windowAt(first, limit_epochs);
        self.channels.prepare(first, count, self.geometry, &self.power.state, &self.events) catch |e| return self.fail(e);
        self.runWindow(first, if (out) |o| .{ .epochs = count, .first = first, .gain = self.gain.linear().factor, .out = o[0 .. count * self.bytesPerEpoch()] } else null);
        self.epoch = first.plus(count);
        return count;
    }

    fn fail(self: *Run, e: GenerationError) GenerationError {
        self.failure = e;
        return e;
    }

    fn windowAt(self: *const Run, first: Epoch, max: u64) u32 {
        var count = @min(max, gain.epochsToEvaluation(first));
        count = @min(count, geometry.block_epochs - first.ms % geometry.block_epochs);
        if (self.commands.nextAfter(first)) |e| count = @min(count, e.ms - first.ms);
        if (self.power.state.nextAfter(first)) |e| count = @min(count, e.ms - first.ms);
        return @intCast(count);
    }

    fn applyDue(self: *Run, epoch: Epoch, offset: usize) error{OutOfMemory}!usize {
        const n = try self.commands.applyDue(self.gpa, &self.channels.log, epoch, self.applied[offset..]);
        for (0..n) |i| {
            self.events.push(.{ .command_applied = .{ .epoch = epoch, .index = @intCast(offset + i) } });
        }
        self.power.advance(&self.channels.log, epoch);
        return n;
    }

    fn runJob(self: *Run, job: Job) void {
        const count = switch (job) {
            .correct => |tracks| tracks,
            .produce => |work| blk: {
                const epochs = if (work.samples) |samples| samples.epochs else 0;
                for (self.ready[0..epochs]) |*ready| ready.store(false, .monotonic);
                break :blk epochs * (1 + self.sub_tiles) + if (work.rows) |rows| rows.count else 0;
            },
        };
        if (self.pool) |pool| pool.run(job, count) else {
            var i: u32 = 0;
            while (i < count) : (i += 1) self.runTask(0, job, i);
        }
    }

    fn produceBlock(self: *Run, index: u64, samples: ?SampleJob) void {
        const first: Epoch = .{ .ms = index * geometry.block_epochs };
        const count = @min(geometry.block_epochs, self.span.epochs - first.ms);
        self.geometry.beginBlock(first, count);
        // Channels change only at re-plans, which open blocks.
        const every = first.ms % replan_epochs == 0 or self.geometry.dump_writer != null;
        @memset(self.geometry.needed, every);
        if (!every) for (self.channels.active.channels.items) |channel| {
            self.geometry.needed[channel.track] = true;
        };
        const through = self.passesThrough(first, count) and !self.geometry.refreshInside(first, count);
        const skipped = through and !self.readsEnds(first, count);
        if (skipped) self.geometry.skip() else if (through) self.geometry.endsOnly();
        var pending = samples;
        while (self.geometry.nextSegment(&self.events)) |segment| {
            // Track corrections finish before any row of their segment is produced.
            if (self.geometry.observation.moved()) self.runJob(.{ .correct = @intCast(self.geometry.observation.entries.len) });
            if (skipped) continue;
            if (pending == null and segment.count <= 2) {
                for (0..segment.count) |k| self.geometry.produceRows(segment.first.plus(k));
            } else self.runJob(.{ .produce = .{ .rows = segment, .samples = pending } });
            pending = null;
        }
        self.geometry.dumpRows() catch {};
        self.blocks_produced = index + 1;
    }

    fn passesThrough(self: *const Run, first: Epoch, count: u32) bool {
        const target = self.seek_to orelse return false;
        if (first.ms / geometry.block_epochs >= target.ms / geometry.block_epochs or self.geometry.dump_writer != null or self.channels.dump_params != null or self.channels.dump_plan != null) return false;
        if (self.commands.nextAfter(first)) |epoch| if (epoch.ms < first.ms + count) return false;
        if (self.power.state.nextAfter(first)) |epoch| if (epoch.ms < first.ms + count) return false;
        return true;
    }

    // A refresh reads the preceding window, and the target needs the preceding block's last row.
    fn readsEnds(self: *const Run, first: Epoch, count: u32) bool {
        const target = self.seek_to.?;
        if (first.ms / geometry.block_epochs + 1 == target.ms / geometry.block_epochs) return true;
        return self.channels.messages.dueWithin(time.atEpoch(self.span.start, first), time.atEpoch(self.span.start, first.plus(count + geometry.block_epochs)));
    }

    fn runWindow(self: *Run, first: Epoch, samples: ?SampleJob) void {
        const next = first.ms / geometry.block_epochs + 1;
        if (next * geometry.block_epochs < self.span.epochs and self.blocks_produced <= next) {
            self.produceBlock(next, samples);
        } else if (samples) |work| self.runJob(.{ .produce = .{ .samples = work } });
    }
};

pub fn eventCheckpoint(run: *const Run) usize {
    return run.events.count();
}

pub fn discardEventsAfter(run: *Run, checkpoint: usize) void {
    run.events.truncate(checkpoint);
}
