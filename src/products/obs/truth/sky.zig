const std = @import("std");
const tracking = @import("simulation/tracking/track");
const time = @import("domain/time/gps");
const windows = @import("simulation/geometry/window");
const receiver = @import("simulation/geometry/receiver");
const flight = @import("simulation/model/flight_plan");
const geometry = @import("simulation/geometry/geometry");
const linear = @import("base/math/linear");
const gnss_types = @import("domain/gnss_types");

const Payload = @import("domain/signals/payload").Payload;

const Mark = tracking.Mark;
const Epoch = time.Epoch;

const checkpoint_ms: u64 = 600_000;
const Checkpoint = struct { ms: u64, marks: []Mark };

pub const Satellite = struct {
    sat: gnss_types.SatId,
    record: bool,
    above_mask: bool,
    masked_out: bool,
    az_rad: f64,
    el_rad: f64,
};

pub const Dop = struct { pdop: f64, hdop: f64, vdop: f64 };

pub const Inputs = struct {
    window: windows.Inputs,
    signals: std.EnumSet(gnss_types.Signal),
    mask_out: *const std.EnumArray(gnss_types.System, gnss_types.SatSet),
};

pub const Sky = struct {
    gpa: std.mem.Allocator,
    mask_out: *const std.EnumArray(gnss_types.System, gnss_types.SatSet),
    window: windows.Window,
    checkpoints: std.ArrayList(Checkpoint) = .empty,
    queried: ?Epoch = null,
    satellites: []Satellite,
    indices: [256]?u8 = @splat(null),
    receiver_cache: ?struct { epoch: Epoch, frame: receiver.Frame } = null,
    all_key: ?struct { epoch: Epoch, mask: f64 } = null,

    pub fn init(gpa: std.mem.Allocator, input: Inputs, payload: *const Payload) error{OutOfMemory}!Sky {
        var window = try windows.Window.init(gpa, input.window, input.signals, payload, .initFill(.empty));
        errdefer window.deinit(gpa);
        const satellites = try gpa.alloc(Satellite, window.tracks.len);
        var self: Sky = .{ .gpa = gpa, .mask_out = input.mask_out, .window = window, .satellites = satellites };
        for (window.tracks, 0..) |track, i| self.indices[track.sat.key()] = @intCast(i);
        return self;
    }

    pub fn deinit(self: *Sky) void {
        for (self.checkpoints.items) |c| self.gpa.free(c.marks);
        self.checkpoints.deinit(self.gpa);
        self.gpa.free(self.satellites);
        self.window.deinit(self.gpa);
    }

    pub fn all(self: *Sky, e: Epoch, mask: f64) error{OutOfMemory}![]const Satellite {
        try self.seekTo(e, null);
        if (self.all_key) |previous| if (previous.epoch.ms == e.ms and previous.mask == mask) return self.satellites;
        const t = time.atEpoch(self.window.input.start, e);
        for (self.window.tracks, self.satellites) |*track, *out| out.* = self.satellite(track.sat, track.ready(), t, mask);
        self.all_key = .{ .epoch = e, .mask = mask };
        return self.satellites;
    }

    pub fn target(self: *Sky, e: Epoch, sat: gnss_types.SatId, mask: f64) error{OutOfMemory}!?Satellite {
        try self.seekTo(e, sat);
        const i = self.indices[sat.key()] orelse return null;
        const track = &self.window.tracks[i];
        return self.satellite(track.sat, track.ready(), time.atEpoch(self.window.input.start, e), mask);
    }

    pub fn provider(self: *Sky, sat: gnss_types.SatId) ?*tracking.Track {
        const i = self.indices[sat.key()] orelse return null;
        return &self.window.tracks[i].ephemeris;
    }

    fn advance(self: *Sky, e: Epoch, selected: ?gnss_types.SatId) void {
        if (selected) |sat| {
            _ = self.window.advanceTarget(e, sat);
        } else {
            _ = self.window.advance(e);
        }
    }

    fn seekTo(self: *Sky, e: Epoch, selected: ?gnss_types.SatId) error{OutOfMemory}!void {
        if (self.queried) |q| if (e.ms < q.ms and self.crossed(e, q)) {
            var i = self.checkpoints.items.len;
            while (self.checkpoints.items[i - 1].ms > e.ms) i -= 1;
            self.window.restore(self.checkpoints.items[i - 1].marks);
        };
        var next: u64 = if (self.checkpoints.last()) |c| c.ms + checkpoint_ms else 0;
        while (next <= e.ms) : (next += checkpoint_ms) {
            try self.checkpoints.ensureUnusedCapacity(self.gpa, 1);
            const marks = try self.gpa.alloc(Mark, self.window.tracks.len);
            self.advance(.{ .ms = next }, selected);
            self.window.mark(marks);
            self.checkpoints.appendAssumeCapacity(.{ .ms = next, .marks = marks });
            self.queried = .{ .ms = next };
        }
        self.advance(e, selected);
        self.queried = e;
        if (self.receiver_cache == null or self.receiver_cache.?.epoch.ms != e.ms) {
            self.receiver_cache = .{ .epoch = e, .frame = receiver.atMs(self.window.input.trajectory, e.ms) };
        }
    }

    fn crossed(self: *const Sky, from: Epoch, to: Epoch) bool {
        const a = time.atEpoch(self.window.input.start, from);
        const z = time.atEpoch(self.window.input.start, to);
        for (gnss_types.System.all) |system| {
            if (!z.lessThan(flight.nextLegBoundary(system, a, self.window.input.ephemerides.flight_plan.leap))) return true;
        }
        return false;
    }

    fn satellite(self: *const Sky, sat: gnss_types.SatId, ready: ?geometry.Ready, t: time.GpsTime, mask: f64) Satellite {
        const columns = if (ready) |value| value.columnsAt(t) else null;
        return .{
            .sat = sat,
            .record = columns != null,
            .above_mask = if (columns) |s| s.el_rad >= mask else false,
            .masked_out = self.mask_out.get(sat.system).contains(sat),
            .az_rad = if (columns) |s| s.az_rad else 0,
            .el_rad = if (columns) |s| s.el_rad else 0,
        };
    }
};

pub const Geometry = struct {
    normal: [4][4]f64 = @splat(@splat(0)),
    count: usize = 0,

    pub fn add(self: *Geometry, az_rad: f64, el_rad: f64) void {
        const h = @cos(el_rad);
        const row = [4]f64{ h * @sin(az_rad), h * @cos(az_rad), @sin(el_rad), 1 };
        for (0..4) |i| for (0..4) |j| {
            self.normal[i][j] += row[i] * row[j];
        };
        self.count += 1;
    }

    pub fn dilution(self: *Geometry) ?Dop {
        if (self.count < 4) return null;
        var identity: [4][4]f64 = @splat(@splat(0));
        for (0..4) |i| identity[i][i] = 1;
        const q = linear.solve(4, 4, &self.normal, &identity);
        const east = q[0][0];
        const north = q[1][1];
        const up = q[2][2];
        if (!(east > 0 and north > 0 and up > 0 and std.math.isFinite(east + north + up))) return null;
        return .{ .pdop = @sqrt(east + north + up), .hdop = @sqrt(east + north), .vdop = @sqrt(up) };
    }
};
