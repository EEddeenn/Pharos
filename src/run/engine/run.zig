const std = @import("std");
const Io = std.Io;
const core = @import("shared").core;
const GpsTime = core.time.GpsTime;
const Epoch = core.time.Epoch;
const noise = @import("../synth.zig").noise;
pub const NoiseMode = noise.Mode;
const kernel = @import("../synth.zig").kernel;
const gain = @import("../synth.zig").gain;
const Gain = gain.Gain;
const events = @import("events.zig");
const commands = @import("commands.zig");
const workers = @import("workers.zig");
const geometry = @import("geometry.zig");
const Ionosphere = @import("shared").stage.ionosphere.Ionosphere;
const messages = @import("shared").stage.messages;
const Power = @import("shared").stage.power.Power;
const replan_epochs = @import("shared").stage.channels.replan_epochs;
const ChannelStage = @import("channels.zig").Stage;
const bundle = @import("shared").bundle;

comptime {
    std.debug.assert(replan_epochs % geometry.block_epochs == 0);
}

const window_epochs = @min(geometry.block_epochs, gain.evaluation_epochs);

pub const Options = struct {
    seed: u64 = 0,
    workers: u32 = 0,
    noise: NoiseMode = .counter,
    gain: ?gain.Db = null,
    dumps: Dumps = .{},
};

pub const Dumps = struct {
    rows: ?*Io.Writer = null,
    plan: ?*Io.Writer = null,
    params: ?*Io.Writer = null,
};

const StepError = @import("channels.zig").Error;

pub const CreateError = StepError || error{ThreadSpawnFailed};
pub const PullError = StepError;
pub const SeekError = StepError || error{ EpochOutOfRange, AdaptiveGain, CommandsApplied };

const Reasoned = PullError || SeekError || error{ThreadSpawnFailed};

pub fn reason(e: Reasoned) []const u8 {
    return switch (e) {
        error.MissingEarthOrientation, error.MissingTimeOffset, error.MissingUtcParameters, error.MessageSet => |failure| messages.reason(failure),
        error.ThreadSpawnFailed => "a worker thread could not be started",
        error.EpochOutOfRange => "the epoch lies beyond the end of the run",
        error.AdaptiveGain => "the adaptive AGC depends on every epoch before the target",
        error.CommandsApplied => "the seek starts the run over, which would drop the commands it has applied",
        error.OutOfMemory => "out of memory",
        error.Internal => "a failure no input explains",
    };
}

pub const Info = struct {
    samples: bundle.scenario.Samples,
    samples_per_epoch: u32,
    bytes_per_epoch: usize,
    span: bundle.Span,
    workers: u32,
};

pub const Block = struct {
    epoch_first: Epoch,
    epochs: u32 = 0,
    bytes: usize = 0,
    clipped: u64 = 0,
    applied: []const commands.Applied = &.{},
    failed: ?StepError = null,
};

pub const Run = struct {
    pub const Job = struct { epochs: u32 = 0, first: Epoch = .zero, gain: f32 = 1, out: []u8 = &.{}, rows: geometry.Segment = .{ .first = .zero, .count = 0 }, tracks: u32 = 0 };

    gpa: std.mem.Allocator,
    threaded: Io.Threaded,
    options: Options,
    info: Info,
    pool: ?*workers.Pool(Run),
    scratch: []kernel.Scratch,
    geometry: *geometry.Stage,
    channels: *ChannelStage,
    power: Power,
    blocks_produced: u64 = 0,
    kernel_config: kernel.Config,
    sub_tiles: u32,
    clipped: std.atomic.Value(u64) = .init(0),
    ready: [window_epochs]std.atomic.Value(bool) = undefined,
    epoch: Epoch = .zero,
    gain: Gain,
    total_clipped: u64 = 0,
    total_bytes: u64 = 0,
    failed: ?StepError = null,
    events: events.Ring = .{},
    commands: commands.Queue = .{},
    applied: [commands.capacity]commands.Applied = undefined,
    next_power: usize = 0,

    pub fn create(gpa: std.mem.Allocator, b: *const bundle.Bundle, samples: bundle.scenario.Samples, options: Options) CreateError!*Run {
        const scenario = &b.scenario;
        const spe = samples.sample_rate.samplesPerEpoch();
        const bytes_per_epoch = samples.format.bytesFor(spe);
        const opts = normalizedOptions(options);
        const sub_tile = kernel.subTileFor(spe);
        const kernel_config: kernel.Config = .{
            .samples_per_epoch = spe,
            .sub_tile_len = sub_tile,
            .format = samples.format,
            .noise = opts.noise,
            .seed = opts.seed,
        };
        const stage = try geometry.Stage.init(gpa, b);
        errdefer stage.deinit();
        const channels = try ChannelStage.init(gpa, b, stage.resolved(), .{ .samples = samples, .window_epochs = window_epochs, .dump_params = opts.dumps.params, .dump_plan = opts.dumps.plan });
        errdefer channels.deinit();
        const power = Power.init(scenario.power);
        const self = try gpa.create(Run);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = .init_single_threaded,
            .options = opts,
            .info = .{
                .samples = samples,
                .samples_per_epoch = spe,
                .bytes_per_epoch = bytes_per_epoch,
                .span = b.span(),
                .workers = opts.workers,
            },
            .pool = null,
            .scratch = &.{},
            .geometry = stage,
            .channels = channels,
            .power = power,
            .gain = .of(opts.gain),
            .kernel_config = kernel_config,
            .sub_tiles = kernel.subTiles(kernel_config),
        };
        if (opts.workers > 1) {
            self.pool = workers.Pool(Run).init(gpa, self.threaded.io(), self, opts.workers - 1) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ThreadSpawnFailed,
            };
        }
        errdefer if (self.pool) |p| p.deinit(gpa);
        self.scratch = try allocScratch(gpa, opts.workers, sub_tile, kernel.expandSlack(channels.maxSamplesPerEntry()));
        errdefer freeScratch(gpa, self.scratch);
        try self.begin();
        return self;
    }

    fn begin(self: *Run) StepError!void {
        if (self.info.span.epochs == 0) return;
        self.produceBlock(0, .{});
        try self.channels.plan(.zero, 1, self.geometry, &self.events);
    }

    pub fn ionosphere(self: *const Run) *const Ionosphere {
        return &self.geometry.ionosphere;
    }

    fn normalizedOptions(options: Options) Options {
        var opts = options;
        if (opts.workers == 0) opts.workers = @intCast(std.Thread.getCpuCount() catch 1);
        return opts;
    }

    fn allocScratch(gpa: std.mem.Allocator, slots: usize, sub_tile_len: u32, slack: u32) error{OutOfMemory}![]kernel.Scratch {
        const scratch = try gpa.alloc(kernel.Scratch, slots);
        errdefer gpa.free(scratch);
        var made: usize = 0;
        errdefer for (scratch[0..made]) |*s| s.deinit();
        for (scratch) |*s| {
            s.* = try kernel.Scratch.init(gpa, sub_tile_len, slack);
            made += 1;
        }
        return scratch;
    }

    fn freeScratch(gpa: std.mem.Allocator, scratch: []kernel.Scratch) void {
        for (scratch) |*s| s.deinit();
        gpa.free(scratch);
    }

    pub fn generatedSignals(self: *const Run) std.EnumSet(core.types.Signal) {
        return self.channels.table.generated;
    }

    pub fn entryEpoch(self: *const Run) Epoch {
        return self.channels.table.entry_epoch;
    }

    pub fn entryTime(self: *const Run) GpsTime {
        return core.time.atEpoch(self.info.span.start, self.entryEpoch());
    }

    pub fn destroy(self: *Run) void {
        if (self.pool) |p| p.deinit(self.gpa);
        self.channels.deinit();
        self.geometry.deinit();
        freeScratch(self.gpa, self.scratch);
        self.gpa.destroy(self);
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

    pub fn pull(self: *Run, out: []u8, max_epochs: u32) error{BufferTooSmall}!Block {
        const bpe = self.info.bytes_per_epoch;
        if (self.failed) |e| return .{ .epoch_first = self.epoch, .failed = e };
        const left = self.info.span.epochs - self.epoch.ms;
        if (left == 0) return .{ .epoch_first = self.epoch };
        const fit = @min(out.len / bpe, max_epochs);
        if (fit == 0) return error.BufferTooSmall;
        const epochs = @min(left, fit);
        const first = self.epoch;
        var produced: u32 = 0;
        var clipped: u64 = 0;
        var applied_count: usize = 0;
        const failed: ?StepError = while (produced < epochs) {
            const count = self.step(epochs - produced, out[produced * bpe ..], &applied_count) catch |e| break e;
            const window_sum = self.clipped.swap(0, .monotonic);
            clipped += window_sum;
            self.total_clipped += window_sum;
            self.total_bytes += count * bpe;
            produced += count;
            const components = @as(u64, count) * self.info.samples_per_epoch * 2;
            if (self.gain.account(self.epoch, window_sum, components)) |adj| self.events.push(.{ .agc = adj });
        } else null;
        return .{
            .epoch_first = first,
            .epochs = produced,
            .bytes = produced * bpe,
            .clipped = clipped,
            .applied = self.applied[0..applied_count],
            .failed = failed,
        };
    }

    pub fn seek(self: *Run, target_epoch: Epoch) SeekError!void {
        if (self.gain == .adaptive) return error.AdaptiveGain;
        if (target_epoch.ms > self.info.span.epochs) return error.EpochOutOfRange;
        if (target_epoch.ms < self.epoch.ms or self.failed != null) {
            if (self.commands.taken != 0) return error.CommandsApplied;
            try self.restart();
        }
        var applied_count: usize = 0;
        self.events.retainSwitches(target_epoch);
        while (self.epoch.ms < target_epoch.ms) : (self.events.retainSwitches(target_epoch)) {
            _ = try self.step(target_epoch.ms - self.epoch.ms, null, &applied_count);
        }
        self.channels.table.enter(target_epoch, &self.events);
        self.total_clipped = 0;
        self.total_bytes = 0;
    }

    fn restart(self: *Run) StepError!void {
        self.geometry.reset();
        self.channels.reset() catch |e| return self.fail(e);
        self.power.reset();
        self.next_power = 0;
        self.events.truncate(0);
        self.epoch = .zero;
        self.blocks_produced = 0;
        self.failed = null;
        self.begin() catch |e| return self.fail(e);
    }

    fn step(self: *Run, limit_epochs: u64, out: ?[]u8, applied_count: *usize) StepError!u32 {
        const first = self.epoch;
        applied_count.* += self.applyDue(first, applied_count.*) catch |e| return self.fail(e);
        const count = self.windowAt(first, limit_epochs);
        self.channels.prepare(first, count, self.geometry, &self.power, &self.events) catch |e| return self.fail(e);
        self.runWindow(if (out) |o| .{ .epochs = count, .first = first, .gain = self.gain.linear().factor, .out = o[0 .. count * self.info.bytes_per_epoch] } else .{ .first = first });
        self.epoch = first.plus(count);
        return count;
    }

    fn fail(self: *Run, e: StepError) StepError {
        self.failed = e;
        return e;
    }

    fn windowAt(self: *const Run, first: Epoch, max: u64) u32 {
        var count = @min(max, gain.epochsToEvaluation(first));
        count = @min(count, geometry.block_epochs - first.ms % geometry.block_epochs);
        if (self.commands.nextAfter(first)) |e| count = @min(count, e.ms - first.ms);
        if (self.power.nextAfter(first)) |e| count = @min(count, e.ms - first.ms);
        return @intCast(count);
    }

    fn applyDue(self: *Run, epoch: Epoch, offset: usize) error{OutOfMemory}!usize {
        const n = try self.commands.applyDue(self.gpa, &self.channels.log, epoch, self.applied[offset..]);
        for (0..n) |i| {
            self.events.push(.{ .command_applied = .{ .epoch = epoch, .index = @intCast(offset + i) } });
        }
        self.channels.log.powerTo(&self.power, &self.next_power, epoch);
        return n;
    }

    fn runJob(self: *Run, job: Job) void {
        const count = job.epochs * (1 + self.sub_tiles) + job.rows.count + job.tracks;
        for (self.ready[0..job.epochs]) |*r| r.store(false, .monotonic);
        if (self.pool) |p| p.run(job, count) else {
            var i: u32 = 0;
            while (i < count) : (i += 1) self.runTask(0, job, i);
        }
    }

    fn produceBlock(self: *Run, index: u64, window: Job) void {
        const first: Epoch = .{ .ms = index * geometry.block_epochs };
        const count = @min(geometry.block_epochs, self.info.span.epochs - first.ms);
        self.geometry.beginBlock(first, count);
        // Channels change only at re-plans, which open blocks; between them a block needs rows only for the channels held now.
        const every = first.ms % replan_epochs == 0 or self.options.dumps.rows != null;
        @memset(self.geometry.needed, every);
        if (!every) for (self.channels.table.channels.items) |c| {
            self.geometry.needed[c.track] = true;
        };
        var job = window;
        while (self.geometry.nextSegment(&self.events)) |segment| {
            // The tracks that moved are corrected, all of them, before any row of the segment is made.
            if (self.geometry.observation.moved()) self.runJob(.{ .tracks = @intCast(self.geometry.observation.entries.len) });
            // A row or two alone are not worth waking the workers for.
            if (job.epochs == 0 and segment.count <= 2) {
                for (0..segment.count) |k| self.geometry.produceRows(segment.first.plus(k));
            } else {
                job.rows = segment;
                self.runJob(job);
            }
            job.epochs = 0;
        }
        if (self.options.dumps.rows) |w| self.geometry.dumpRows(w) catch {};
        self.blocks_produced = index + 1;
    }

    fn runWindow(self: *Run, window: Job) void {
        const next = window.first.ms / geometry.block_epochs + 1;
        if (next * geometry.block_epochs < self.info.span.epochs and self.blocks_produced <= next) {
            self.produceBlock(next, window);
        } else if (window.epochs > 0) {
            self.runJob(window);
        }
    }

    pub fn runTask(self: *Run, worker_id: usize, job: Job, index: u32) void {
        if (job.tracks != 0) return self.geometry.observation.correct(index);
        if (index < job.epochs) {
            self.channels.deriveEpoch(index, &self.power);
            return self.ready[index].store(true, .release);
        }
        const tiles = self.sub_tiles;
        const t = index - job.epochs;
        if (t >= job.epochs * tiles) return self.geometry.produceRows(job.rows.first.plus(t - job.epochs * tiles));
        const e = t / tiles;
        // The epoch's parameters come from a task given out before this one.
        while (!self.ready[e].load(.acquire)) std.atomic.spinLoopHint();
        const bpe = self.info.bytes_per_epoch;
        const slot = job.out[e * bpe ..][0..bpe];
        _ = self.clipped.fetchAdd(kernel.synthSubTile(self.kernel_config, &self.channels.tables, self.channels.epochRows(e), job.first.plus(e), t % tiles, job.gain, &self.scratch[worker_id], slot), .monotonic);
    }
};
