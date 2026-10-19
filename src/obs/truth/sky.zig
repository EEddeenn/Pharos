const std = @import("std");
const shared = @import("shared");
const core = shared.core;
const gnss = shared.gnss;
const bundle = shared.bundle;
const geo = shared.geo;
const Mark = shared.track.provider.Mark;
const types = core.types;
const Epoch = core.time.Epoch;

const checkpoint_ms: u64 = 600_000;
const Checkpoint = struct { ms: u64, marks: []Mark };

pub const Satellite = struct {
    sat: types.SatId,
    record: bool,
    above_mask: bool,
    masked_out: bool,
    az_rad: f64,
    el_rad: f64,
};

pub const Dop = struct { pdop: f64, hdop: f64, vdop: f64 };

pub const Sky = struct {
    gpa: std.mem.Allocator,
    b: *const bundle.Bundle,
    span: bundle.Span,
    window: geo.Window,
    checkpoints: std.ArrayList(Checkpoint) = .empty,
    queried: ?Epoch = null,
    satellites: []Satellite,
    indices: [256]?u8 = @splat(null),
    sampled: ?Epoch = null,
    all_epoch: ?Epoch = null,
    all_mask: f64 = 0,
    receiver: geo.receiver.Frame = undefined,

    pub fn init(gpa: std.mem.Allocator, b: *const bundle.Bundle, payload: *const gnss.payload.Payload) error{OutOfMemory}!Sky {
        var window = try geo.Window.init(gpa, b, payload, .initFill(.empty));
        errdefer window.deinit(gpa);
        const satellites = try gpa.alloc(Satellite, window.tracks.len);
        var self: Sky = .{ .gpa = gpa, .b = b, .span = b.span(), .window = window, .satellites = satellites };
        for (window.tracks, 0..) |track, i| self.indices[track.sat.key()] = @intCast(i);
        return self;
    }

    pub fn deinit(self: *Sky) void {
        for (self.checkpoints.items) |c| self.gpa.free(c.marks);
        self.checkpoints.deinit(self.gpa);
        self.gpa.free(self.satellites);
        self.window.deinit(self.gpa);
    }

    fn advance(self: *Sky, e: Epoch, selected: ?types.SatId) void {
        if (selected) |sat| {
            _ = self.window.advanceTarget(e, sat);
        } else {
            _ = self.window.advance(e);
        }
    }

    fn seekTo(self: *Sky, e: Epoch, selected: ?types.SatId) error{OutOfMemory}!void {
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
        if (self.sampled == null or self.sampled.?.ms != e.ms) {
            self.receiver = geo.receiver.atMs(&self.b.trajectory, e.ms);
            self.sampled = e;
        }
    }

    fn crossed(self: *const Sky, from: Epoch, to: Epoch) bool {
        const a = core.time.atEpoch(self.span.start, from);
        const z = core.time.atEpoch(self.span.start, to);
        for (types.System.all) |system| {
            if (!z.lessThan(bundle.plan.nextLegBoundary(system, a, self.b.plan.leap))) return true;
        }
        return false;
    }

    fn satellite(self: *const Sky, entry: geo.geometry.Entry, t: core.time.GpsTime, mask: f64) Satellite {
        const columns = if (entry.ready()) |ready| ready.columnsAt(t) else null;
        return .{
            .sat = entry.sat,
            .record = columns != null,
            .above_mask = if (columns) |s| s.el_rad >= mask else false,
            .masked_out = self.b.scenario.mask_out.get(entry.sat.system).contains(entry.sat),
            .az_rad = if (columns) |s| s.az_rad else 0,
            .el_rad = if (columns) |s| s.el_rad else 0,
        };
    }

    pub fn all(self: *Sky, e: Epoch, mask: f64) error{OutOfMemory}![]const Satellite {
        try self.seekTo(e, null);
        if (self.all_epoch) |previous| if (previous.ms == e.ms and self.all_mask == mask) return self.satellites;
        const t = core.time.atEpoch(self.span.start, e);
        for (self.window.frame().tracks, self.satellites) |entry, *out| out.* = self.satellite(entry, t, mask);
        self.all_epoch = e;
        self.all_mask = mask;
        return self.satellites;
    }

    pub fn target(self: *Sky, e: Epoch, sat: types.SatId, mask: f64) error{OutOfMemory}!?Satellite {
        try self.seekTo(e, sat);
        const i = self.indices[sat.key()] orelse return null;
        return self.satellite(self.window.frame().tracks[i], core.time.atEpoch(self.span.start, e), mask);
    }

    pub fn provider(self: *Sky, sat: types.SatId) ?*shared.track.provider.Track {
        const i = self.indices[sat.key()] orelse return null;
        return &self.window.tracks[i].ephemeris;
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
        const q = core.linear.solve(4, 4, 4, &self.normal, &identity);
        const east = q[0][0];
        const north = q[1][1];
        const up = q[2][2];
        if (!(east > 0 and north > 0 and up > 0 and std.math.isFinite(east + north + up))) return null;
        return .{ .pdop = @sqrt(east + north + up), .hdop = @sqrt(east + north), .vdop = @sqrt(up) };
    }
};
