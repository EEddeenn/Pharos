const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const types = core.types;
const GpsTime = core.time.GpsTime;
const Epoch = core.time.Epoch;
const Delays = @import("shared").track.provider.Delays;
const bundle = @import("shared").bundle;
const geo = @import("shared").geo;
const events = @import("events.zig");
const Ionosphere = @import("shared").stage.ionosphere.Ionosphere;
const Broadcast = @import("shared").stage.ionosphere.Broadcast;
const replan_epochs = @import("shared").stage.channels.replan_epochs;

pub const block_epochs: u32 = 100;

pub const Row = struct {
    sat: types.SatId,
    seen: ?Seen,

    pub const Seen = struct {
        delays: Delays,
        epoch: geo.observation.SatEpoch,
    };
};

const RowBuffer = struct { rows: []Row, first: Epoch = .zero, count: u32 = 0, valid: bool = false };

pub const Segment = struct { first: Epoch, count: u32 };

pub const Error = error{OutOfMemory};

pub const Resolved = struct {
    allocation: *const gnss.allocation.Allocation,
    broadcast: Broadcast,
    models: *const core.iono.Models,
    tracks: []const geo.observation.Entry,
};

pub const Stage = struct {
    gpa: std.mem.Allocator,
    start: GpsTime,
    allocation: gnss.allocation.Allocation,
    observation: geo.Observation,
    b: *const bundle.Bundle,
    ionosphere: Ionosphere,
    buffers: [2]RowBuffer,
    writing: u1 = 1,
    at: Epoch = .zero,
    rows_per_epoch: usize,
    needed: []bool,

    pub fn init(gpa: std.mem.Allocator, b: *const bundle.Bundle) Error!*Stage {
        const scenario = &b.scenario;
        const self = try gpa.create(Stage);
        errdefer gpa.destroy(self);
        var ionosphere = try Ionosphere.create(gpa, &scenario.ionosphere.ready, scenario.signals);
        errdefer ionosphere.deinit(gpa);
        self.* = .{
            .gpa = gpa,
            .start = scenario.start,
            .allocation = gnss.allocation.at(scenario.start),
            .observation = undefined,
            .b = b,
            .ionosphere = ionosphere,
            .buffers = undefined,
            .rows_per_epoch = 0,
            .needed = undefined,
        };
        self.observation = try geo.Observation.init(gpa, b, &self.allocation, &self.ionosphere.models, scenario.mask_out);
        errdefer self.observation.deinit(gpa);
        const count = self.observation.window.tracks.len;
        const rows_per_buffer = (@as(usize, block_epochs) + 1) * count;
        const rows_a = try gpa.alloc(Row, rows_per_buffer);
        errdefer gpa.free(rows_a);
        const rows_b = try gpa.alloc(Row, rows_per_buffer);
        errdefer gpa.free(rows_b);
        self.needed = try gpa.alloc(bool, count);
        self.buffers = .{ .{ .rows = rows_a }, .{ .rows = rows_b } };
        self.rows_per_epoch = count;
        self.reset();
        return self;
    }

    pub fn deinit(self: *Stage) void {
        self.observation.deinit(self.gpa);
        self.ionosphere.deinit(self.gpa);
        for (self.buffers) |b| self.gpa.free(b.rows);
        self.gpa.free(self.needed);
        self.gpa.destroy(self);
    }

    pub fn reset(self: *Stage) void {
        for (&self.buffers) |*buffer| buffer.* = .{ .rows = buffer.rows };
        self.writing = 1;
        self.at = .zero;
        self.observation.reset();
        _ = self.observation.advance(.zero);
    }

    pub fn resolved(self: *const Stage) Resolved {
        return .{ .allocation = &self.allocation, .broadcast = self.ionosphere.broadcast, .models = &self.ionosphere.models, .tracks = self.observation.frame().tracks };
    }

    fn reselectAt(self: *Stage, epoch: Epoch, ring: *events.Ring) void {
        const switched_sats = self.observation.advance(epoch);
        for (types.System.all) |system| {
            const switched = switched_sats.get(system);
            var sats = system.satellites();
            while (sats.next()) |sat| if (switched.contains(sat)) ring.push(.{ .ephemeris_switched = .{ .epoch = epoch, .sat = sat } });
        }
    }

    pub fn beginBlock(self: *Stage, first: Epoch, count: u32) void {
        std.debug.assert(first.ms >= self.observation.base().ms and count <= block_epochs);
        self.writing ^= 1;
        const buffer = &self.buffers[self.writing];
        buffer.* = .{ .rows = buffer.rows, .first = first, .count = count, .valid = true };
        self.at = first;
    }

    pub fn nextSegment(self: *Stage, ring: *events.Ring) ?Segment {
        const buffer = &self.buffers[self.writing];
        const last = buffer.first.plus(buffer.count);
        const first = self.at;
        if (first.ms > last.ms) return null;
        self.reselectAt(first, ring);
        const end = self.segmentEnd(first, last);
        self.at = end.plus(1);
        return .{ .first = first, .count = @intCast(end.ms - first.ms + 1) };
    }

    fn segmentEnd(self: *const Stage, first: Epoch, last: Epoch) Epoch {
        var end: Epoch = .{ .ms = @min(last.ms, self.observation.base().plus(core.time.epochs_per_second - 1).ms) };
        for (self.observation.window.tracks) |*track| {
            const at = track.nextInstant(self.b);
            while (end.ms > first.ms and !core.time.atEpoch(self.start, end).lessThan(at)) end.ms -= 1;
        }
        return end;
    }

    pub fn produceRows(self: *const Stage, epoch: Epoch) void {
        const buffer = &self.buffers[self.writing];
        const slot: usize = @intCast(epoch.ms - buffer.first.ms);
        const rows = buffer.rows[slot * self.rows_per_epoch ..][0..self.rows_per_epoch];
        const rx = geo.receiver.atMs(&self.b.trajectory, epoch.ms);
        const t = core.time.atEpoch(self.start, epoch);
        const every = epoch.ms % replan_epochs == 0;
        for (self.observation.frame().tracks, rows, self.needed) |*track, *row, needed| {
            row.sat = track.sat;
            const ready = (if (every or needed) track.ready() else null) orelse {
                row.seen = null;
                continue;
            };
            row.seen = .{ .delays = ready.delaysAt(t), .epoch = geo.observation.evalSat(ready, rx, t) };
        }
    }

    pub fn rowsAt(self: *const Stage, epoch: Epoch) ?[]const Row {
        for (self.buffers) |b| {
            if (b.valid and epoch.ms >= b.first.ms and epoch.ms <= b.first.ms + b.count) {
                const slot: usize = @intCast(epoch.ms - b.first.ms);
                return b.rows[slot * self.rows_per_epoch ..][0..self.rows_per_epoch];
            }
        }
        return null;
    }

    pub fn dumpRows(self: *const Stage, w: *std.Io.Writer, first: Epoch) std.Io.Writer.Error!void {
        for (self.buffers) |b| {
            if (!b.valid or b.first.ms != first.ms) continue;
            for (0..b.count) |slot| {
                for (b.rows[slot * self.rows_per_epoch ..][0..self.rows_per_epoch]) |row| {
                    const s = (row.seen orelse continue).epoch;
                    try w.print("{d} {f} {f} {f} {f} {f} {f} {f}\n", .{
                        first.ms + slot, row.sat, core.hex.double(s.range_m), core.hex.double(s.clock_s), core.hex.double(s.iono_l1_m), core.hex.double(s.tropo_m), core.hex.double(s.el_rad), core.hex.double(s.az_rad),
                    });
                }
            }
        }
    }
};
