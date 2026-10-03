const std = @import("std");
const Io = std.Io;
const shared = @import("shared");
const core = shared.core;
const bundle = shared.bundle;
const geo = shared.geo;
const formats = @import("formats.zig");
const observe = @import("observe.zig");
const Power = shared.stage.power.Power;
const Commands = shared.stage.commands.Log;
const Ionosphere = shared.stage.ionosphere.Ionosphere;
const replanAt = shared.stage.channels.replanAt;

pub const Error = error{ OutOfMemory, NoSuchOutput };
pub const SubmitError = error{ OutOfMemory, InvalidValue, EpochPassed };
pub const RangeError = error{ Begun, EpochOutOfRange, EmptyRange, NoEpochs };
pub const PullError = error{InvalidBatchSize};
pub const EpochRange = struct { first: u64, end: u64 };
pub const Output = enum(u8) { observation = 0, position = 1 };
pub const max_batch_epochs: u32 = 64;
pub const Summary = struct { first_ms: u64, last_ms: u64, epochs: u64, interval_ms: u32, tracked: ?usize };
pub const Batch = struct { bytes: []const u8, completed_epochs: u64, generated_through: ?u64, end: bool };

pub const Created = struct {
    unix_s: i64,

    pub const min: Created = .{ .unix_s = 0 };
    pub const max: Created = .{ .unix_s = core.civil.daysFromCivil(core.civil.last_year + 1, 1, 1) * 86_400 - 1 };

    pub fn fromUnixSeconds(s: i64) ?Created {
        return if (s >= min.unix_s and s <= max.unix_s) .{ .unix_s = s } else null;
    }

    pub fn fromWallClock(io: Io, read_s: *i64) ?Created {
        read_s.* = Io.Clock.real.now(io).toSeconds();
        return fromUnixSeconds(read_s.*);
    }
};

const Sampler = struct {
    start: core.time.GpsTime,
    interval_ms: u32,
    full_end_ms: u64,
    end: u64,
    first: u64 = 0,
    index: u64 = 0,

    fn init(b: *const bundle.Bundle, interval_ms: u32) Sampler {
        return .{ .start = b.scenario.start, .interval_ms = interval_ms, .full_end_ms = b.epochs() + 1, .end = b.epochs() / interval_ms + 1 };
    }

    fn next(self: *Sampler) ?core.time.Epoch {
        if (self.index >= self.end) return null;
        const epoch: core.time.Epoch = .{ .ms = self.index * self.interval_ms };
        self.index += 1;
        return epoch;
    }

    fn generatedThrough(self: *const Sampler) ?u64 {
        return if (self.index == self.first) null else (self.index - 1) * self.interval_ms;
    }

    fn range(self: *Sampler, requested: EpochRange) error{ EpochOutOfRange, EmptyRange, NoEpochs }!void {
        if (requested.first >= requested.end) return error.EmptyRange;
        if (requested.end > self.full_end_ms) return error.EpochOutOfRange;
        const first = self.indexAtOrAfter(requested.first);
        const end = self.indexAtOrAfter(requested.end);
        if (first >= end) return error.NoEpochs;
        self.first = first;
        self.end = end;
        self.index = first;
    }

    fn indexAtOrAfter(self: *const Sampler, ms: u64) u64 {
        return ms / self.interval_ms + @intFromBool(ms % self.interval_ms != 0);
    }

    fn firstMs(self: *const Sampler) u64 {
        return self.first * self.interval_ms;
    }

    fn lastMs(self: *const Sampler) u64 {
        return (self.end - 1) * self.interval_ms;
    }
};

const Observation = struct {
    evaluator: *observe.Evaluator,
    header: formats.Header,
    power: Power,
    commands: Commands = .{},
    next_command: usize = 0,
};

const Content = union(Output) { observation: Observation, position: bundle.scenario.PositionFormat };

pub const File = struct {
    gpa: std.mem.Allocator,
    bundle: *const bundle.Bundle,
    sampler: Sampler,
    content: Content,
    buffer: []u8,
    stage: enum { header, epochs, done } = .header,

    pub fn create(gpa: std.mem.Allocator, b: *const bundle.Bundle, output: Output, created: Created) Error!*File {
        const interval_ms = switch (output) {
            .observation => (b.scenario.observation orelse return error.NoSuchOutput).interval_ms,
            .position => (b.scenario.position orelse return error.NoSuchOutput).interval_ms,
        };
        const sampler = Sampler.init(b, interval_ms);
        const content: Content = switch (output) {
            .observation => .{ .observation = .{
                .evaluator = try observe.Evaluator.create(gpa, b),
                .header = .{
                    .approx_pos = geo.receiver.atMs(&b.trajectory, sampler.firstMs()).pos,
                    .layout = .init(b.scenario.signals),
                    .interval_ms = interval_ms,
                    .glonass_freq = b.navigation.glonass_freq,
                    .created = core.civil.fromUnix(created.unix_s),
                    .first = b.scenario.start,
                    .last = core.time.atEpoch(b.scenario.start, .{ .ms = sampler.lastMs() }),
                    .moving = b.trajectory.moves(@as(f64, @floatFromInt(b.epochs())) / 1000.0),
                    .leap = b.plan.leap,
                },
                .power = Power.init(b.scenario.power),
            } },
            .position => .{ .position = b.scenario.position.?.format },
        };
        errdefer switch (content) {
            .observation => |o| o.evaluator.destroy(),
            .position => {},
        };
        const epoch_bytes = switch (content) {
            .observation => |o| o.header.layout.epochBytes(o.evaluator.tracked()),
            .position => 1024,
        };
        const buffer = try gpa.alloc(u8, 16 * 1024 + max_batch_epochs * epoch_bytes + 1024);
        errdefer gpa.free(buffer);
        const self = try gpa.create(File);
        self.* = .{ .gpa = gpa, .bundle = b, .sampler = sampler, .content = content, .buffer = buffer };
        return self;
    }

    pub fn destroy(self: *File) void {
        const gpa = self.gpa;
        switch (self.content) {
            .observation => |*o| {
                o.commands.deinit(gpa);
                o.evaluator.destroy();
            },
            .position => {},
        }
        gpa.free(self.buffer);
        gpa.destroy(self);
    }

    pub fn range(self: *File, requested: EpochRange) RangeError!void {
        if (self.stage != .header) return error.Begun;
        try self.sampler.range(requested);
        switch (self.content) {
            .observation => |*o| {
                o.header.first = core.time.atEpoch(self.sampler.start, .{ .ms = self.sampler.firstMs() });
                o.header.last = core.time.atEpoch(self.sampler.start, .{ .ms = self.sampler.lastMs() });
                o.header.approx_pos = geo.receiver.atMs(&self.bundle.trajectory, self.sampler.firstMs()).pos;
            },
            .position => {},
        }
    }

    pub fn fullRange(self: *const File) EpochRange {
        return .{ .first = 0, .end = self.sampler.full_end_ms };
    }

    pub fn summary(self: *const File) Summary {
        return .{
            .first_ms = self.sampler.firstMs(),
            .last_ms = self.sampler.lastMs(),
            .epochs = self.sampler.end - self.sampler.first,
            .interval_ms = self.sampler.interval_ms,
            .tracked = switch (self.content) {
                .observation => |o| o.evaluator.tracked(),
                .position => null,
            },
        };
    }

    pub fn ionosphere(self: *const File) ?*const Ionosphere {
        return switch (self.content) {
            .observation => |o| &o.evaluator.ionosphere,
            .position => null,
        };
    }

    pub fn submit(self: *File, command: bundle.command.Command) SubmitError!void {
        try bundle.command.check(command);
        if (self.sampler.generatedThrough()) |epoch| if (command.apply_at_epoch <= epoch) return error.EpochPassed;
        switch (self.content) {
            .observation => |*o| try o.commands.add(self.gpa, command),
            .position => {},
        }
    }

    pub fn pull(self: *File, max_epochs: u32) PullError!Batch {
        if (max_epochs == 0 or max_epochs > max_batch_epochs) return error.InvalidBatchSize;
        var writer: Io.Writer = .fixed(self.buffer);
        if (self.stage == .header) {
            switch (self.content) {
                .observation => |o| formats.rinexHeader(&writer, o.header) catch unreachable,
                .position => |format| formats.positionHeader(&writer, format) catch unreachable,
            }
            self.stage = .epochs;
        }
        var count: u32 = 0;
        while (self.stage == .epochs and count < max_epochs) : (count += 1) {
            const epoch = self.sampler.next() orelse break;
            switch (self.content) {
                .observation => |*o| {
                    o.commands.powerTo(&o.power, &o.next_command, epoch);
                    const mask = o.commands.maskAt(self.bundle.scenario.elevation_mask_rad, replanAt(epoch, self.bundle.epochs()));
                    const observed = o.evaluator.evaluate(epoch, mask, &o.power);
                    formats.rinexEpoch(&writer, observed, &o.header.layout) catch unreachable;
                },
                .position => |format| {
                    const rx = geo.receiver.atMs(&self.bundle.trajectory, epoch.ms);
                    formats.positionEpoch(&writer, format, core.time.atEpoch(self.sampler.start, epoch), rx.pos, rx.lla) catch unreachable;
                },
            }
        }
        if (self.stage == .epochs and self.sampler.index == self.sampler.end) {
            switch (self.content) {
                .observation => {},
                .position => |format| _ = formats.positionFooter(&writer, format) catch unreachable,
            }
            self.stage = .done;
        }
        return .{
            .bytes = writer.buffered(),
            .completed_epochs = self.sampler.index - self.sampler.first,
            .generated_through = self.sampler.generatedThrough(),
            .end = self.stage == .done,
        };
    }
};
