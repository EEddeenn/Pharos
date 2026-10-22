const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const hex = @import("base/text/hex");
const observation_model = @import("simulation/geometry/observation");
const windows = @import("simulation/geometry/window");
const receiver = @import("simulation/geometry/receiver");
const ionosphere_config = @import("simulation/model/ionosphere");
const ionosphere_state = @import("simulation/state/ionosphere");
const events = @import("products/run/engine/events");

const Payload = @import("domain/signals/payload").Payload;
const Delays = @import("simulation/tracking/track").Delays;

const Epoch = time.Epoch;

pub const block_epochs: u32 = 100;

pub const Row = struct { delays: Delays, epoch: observation_model.SatEpoch };
pub const Segment = struct { first: Epoch, count: u32 };
pub const Error = error{OutOfMemory};

const Mode = enum { dense, endpoints, skipped };
const Block = struct { first: Epoch, epochs: u32, mode: Mode = .dense };
const RowBuffer = struct { storage: []?Row, block: ?Block = null };

pub const WindowRows = union(Mode) { dense: []const ?Row, endpoints: []const ?Row, skipped };

pub const Inputs = struct {
    window: windows.Inputs,
    signals: std.EnumSet(gnss_types.Signal),
    mask_out: std.EnumArray(gnss_types.System, gnss_types.SatSet),
    ionosphere: *const ionosphere_config.Resolved,
    payload: *const Payload,
};

pub const Geometry = struct {
    gpa: std.mem.Allocator,
    observation: observation_model.Observation,
    ionosphere: ionosphere_state.ModelSet,
    ionosphere_info: ionosphere_state.Info,
    buffers: [2]RowBuffer,
    writing: u1 = 1,
    at: Epoch = .zero,
    needed: []bool,
    dump_writer: ?*std.Io.Writer,

    pub fn create(gpa: std.mem.Allocator, input: Inputs, dump_writer: ?*std.Io.Writer) Error!*Geometry {
        const self = try gpa.create(Geometry);
        errdefer gpa.destroy(self);
        var ionosphere = try ionosphere_state.ModelSet.init(gpa, input.ionosphere);
        errdefer ionosphere.deinit(gpa);
        self.* = .{
            .gpa = gpa,
            .observation = undefined,
            .ionosphere = ionosphere,
            .ionosphere_info = .of(input.ionosphere, input.signals),
            .buffers = undefined,
            .needed = undefined,
            .dump_writer = dump_writer,
        };
        self.observation = try observation_model.Observation.init(gpa, input.window, input.signals, input.payload, &self.ionosphere.models, input.mask_out);
        errdefer self.observation.deinit(gpa);
        const count = self.observation.entries.len;
        const rows_per_buffer = (@as(usize, block_epochs) + 1) * count;
        const rows_a = try gpa.alloc(?Row, rows_per_buffer);
        errdefer gpa.free(rows_a);
        const rows_b = try gpa.alloc(?Row, rows_per_buffer);
        errdefer gpa.free(rows_b);
        self.needed = try gpa.alloc(bool, count);
        self.buffers = .{ .{ .storage = rows_a }, .{ .storage = rows_b } };
        self.reset();
        return self;
    }

    pub fn destroy(self: *Geometry) void {
        self.observation.deinit(self.gpa);
        self.ionosphere.deinit(self.gpa);
        for (self.buffers) |b| self.gpa.free(b.storage);
        self.gpa.free(self.needed);
        self.gpa.destroy(self);
    }

    pub fn reset(self: *Geometry) void {
        for (&self.buffers) |*buffer| buffer.block = null;
        self.writing = 1;
        self.at = .zero;
        self.observation.reset();
        _ = self.observation.advance(.zero);
    }

    pub fn beginBlock(self: *Geometry, first: Epoch, count: u32) void {
        std.debug.assert(first.ms >= self.observation.base().ms and count <= block_epochs);
        self.writing ^= 1;
        self.buffers[self.writing].block = .{ .first = first, .epochs = count };
        self.at = first;
    }

    pub fn endsOnly(self: *Geometry) void {
        self.buffers[self.writing].block.?.mode = .endpoints;
    }

    pub fn skip(self: *Geometry) void {
        self.buffers[self.writing].block.?.mode = .skipped;
    }

    // A track refresh at the last row also makes an endpoint-only block insufficient.
    pub fn refreshInside(self: *const Geometry, first: Epoch, count: u32) bool {
        const input = self.observation.window.input;
        const last = time.atEpoch(input.start, first.plus(count));
        for (self.observation.window.tracks) |*track| {
            if (!last.lessThan(track.nextInstant(input.ephemerides.flight_plan))) return true;
        }
        return false;
    }

    pub fn nextSegment(self: *Geometry, ring: *events.Ring) ?Segment {
        const block = self.buffers[self.writing].block.?;
        const last = block.first.plus(block.epochs);
        const first = self.at;
        if (first.ms > last.ms) return null;
        self.reselectAt(first, ring);
        const end = self.segmentEnd(first, last);
        self.at = end.plus(1);
        return .{ .first = first, .count = @intCast(end.ms - first.ms + 1) };
    }

    pub fn produceRows(self: *const Geometry, epoch: Epoch) void {
        const buffer = &self.buffers[self.writing];
        const block = buffer.block.?;
        const count = self.observation.entries.len;
        const slot: usize = @intCast(epoch.ms - block.first.ms);
        const rows = buffer.storage[slot * count ..][0..count];
        if (block.mode == .endpoints and slot > 1 and slot + 1 < block.epochs) {
            @memset(rows, null);
            return;
        }
        const input = self.observation.window.input;
        const rx = if (std.mem.findScalar(bool, self.needed, true) == null) null else receiver.atMs(input.trajectory, epoch.ms);
        const t = time.atEpoch(input.start, epoch);
        for (self.observation.entries, rows, self.needed) |*track, *row, needed| {
            const ready = (if (needed) track.ready() else null) orelse {
                row.* = null;
                continue;
            };
            row.* = .{ .delays = ready.delaysAt(t), .epoch = observation_model.evalSat(ready, rx.?, t) };
        }
    }

    pub fn rowsFor(self: *const Geometry, first: Epoch, count: u32) WindowRows {
        for (self.buffers) |buffer| {
            const block = buffer.block orelse continue;
            if (first.ms < block.first.ms or first.ms + count > block.first.ms + block.epochs) continue;
            if (block.mode == .skipped) return .skipped;
            const slot: usize = @intCast(first.ms - block.first.ms);
            const tracks = self.observation.entries.len;
            const rows = buffer.storage[slot * tracks ..][0 .. (count + 1) * tracks];
            return switch (block.mode) {
                .dense => .{ .dense = rows },
                .endpoints => .{ .endpoints = rows },
                .skipped => unreachable,
            };
        }
        unreachable;
    }

    pub fn dumpRows(self: *const Geometry) std.Io.Writer.Error!void {
        const writer = self.dump_writer orelse return;
        const buffer = &self.buffers[self.writing];
        const block = buffer.block.?;
        const tracks = self.observation.entries;
        for (0..block.epochs) |slot| {
            for (buffer.storage[slot * tracks.len ..][0..tracks.len], tracks) |maybe, track| {
                const row = maybe orelse continue;
                const s = row.epoch;
                try writer.print("{d} {f} {f} {f} {f} {f} {f} {f}\n", .{
                    block.first.ms + slot, track.sat, hex.double(s.range_m), hex.double(s.clock_s), hex.double(s.iono_l1_m), hex.double(s.tropo_m), hex.double(s.el_rad), hex.double(s.az_rad),
                });
            }
        }
    }

    fn reselectAt(self: *Geometry, epoch: Epoch, ring: *events.Ring) void {
        const switched_sats = self.observation.begin(epoch);
        for (gnss_types.System.all) |system| {
            const switched = switched_sats.get(system);
            var sats = system.satellites();
            while (sats.next()) |sat| if (switched.contains(sat)) ring.push(.{ .ephemeris_switched = .{ .epoch = epoch, .sat = sat } });
        }
    }

    fn segmentEnd(self: *const Geometry, first: Epoch, last: Epoch) Epoch {
        const input = self.observation.window.input;
        var end: Epoch = .{ .ms = @min(last.ms, self.observation.base().plus(time.epochs_per_second - 1).ms) };
        for (self.observation.window.tracks) |*track| {
            const at = track.nextInstant(input.ephemerides.flight_plan);
            while (end.ms > first.ms and !time.atEpoch(input.start, end).lessThan(at)) end.ms -= 1;
        }
        return end;
    }
};
