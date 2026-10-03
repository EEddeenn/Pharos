const std = @import("std");
const bitwriter = @import("../../../codec.zig").bitwriter;
const scaling = @import("../../../codec.zig").scaling;
const types = @import("../../../core.zig").types;
const MessageBits = @import("pages.zig").MessageBits;

const Error = bitwriter.Error || error{Layout};
const BoundedWriter = bitwriter.BoundedWriter;

pub const sat_mask_bits = 40;
pub const sig_mask_bits = 16;
const max_systems = 15;

pub const Gnss = enum(u4) { gps = 0, galileo = 2 };

pub const Validity = enum(u4) {
    s5 = 0,
    s10 = 1,
    s15 = 2,
    s20 = 3,
    s30 = 4,
    s60 = 5,
    s90 = 6,
    s120 = 7,
    s180 = 8,
    s240 = 9,
    s300 = 10,
    s600 = 11,
    s900 = 12,
    s1800 = 13,
    s3600 = 14,
    reserved = 15,

    pub fn seconds(self: Validity) ?u32 {
        return switch (self) {
            .s5 => 5,
            .s10 => 10,
            .s15 => 15,
            .s20 => 20,
            .s30 => 30,
            .s60 => 60,
            .s90 => 90,
            .s120 => 120,
            .s180 => 180,
            .s240 => 240,
            .s300 => 300,
            .s600 => 600,
            .s900 => 900,
            .s1800 => 1800,
            .s3600 => 3600,
            .reserved => null,
        };
    }
};

pub const Cell = struct { index: u4, signal: types.Signal, component: types.Component };

pub const gps_cells = [_]Cell{
    .{ .index = 0, .signal = .l1ca, .component = .data },
    .{ .index = 3, .signal = .l1c, .component = .data },
    .{ .index = 4, .signal = .l1c, .component = .pilot },
    .{ .index = 6, .signal = .l2c, .component = .data },
    .{ .index = 7, .signal = .l2c, .component = .pilot },
    .{ .index = 11, .signal = .l5, .component = .data },
    .{ .index = 12, .signal = .l5, .component = .pilot },
};

pub const galileo_cells = [_]Cell{
    .{ .index = 0, .signal = .e1, .component = .data },
    .{ .index = 1, .signal = .e1, .component = .pilot },
    .{ .index = 3, .signal = .e5a, .component = .data },
    .{ .index = 4, .signal = .e5a, .component = .pilot },
    .{ .index = 6, .signal = .e5b, .component = .data },
    .{ .index = 7, .signal = .e5b, .component = .pilot },
    .{ .index = 12, .signal = .e6, .component = .data },
    .{ .index = 13, .signal = .e6, .component = .pilot },
};

pub const SystemMask = struct {
    gnss: Gnss,
    sats: [sat_mask_bits]bool,
    sigs: [sig_mask_bits]bool,
    cells: ?[]const bool,
    nav_message: u3,

    pub fn satCount(self: SystemMask) usize {
        return std.mem.countScalar(bool, &self.sats, true);
    }

    fn sigCount(self: SystemMask) usize {
        return std.mem.countScalar(bool, &self.sigs, true);
    }

    fn cellCount(self: SystemMask) usize {
        if (self.cells) |c| return std.mem.countScalar(bool, c, true);
        return self.satCount() * self.sigCount();
    }
};

pub const Mask = struct {
    systems: []const SystemMask,

    fn satCount(self: Mask) usize {
        var n: usize = 0;
        for (self.systems) |s| n += s.satCount();
        return n;
    }

    fn cellCount(self: Mask) usize {
        var n: usize = 0;
        for (self.systems) |s| n += s.cellCount();
        return n;
    }
};

pub const Orbit = struct { iod: u16, radial_m: ?f64, in_track_m: ?f64, cross_m: ?f64 };

pub const Clock = union(enum) {
    value_m: f64,
    not_available,
    do_not_use,
};

const ClockSubset = struct {
    gnss: Gnss,
    multiplier: u2,
    selected: []const bool,
    values: []const Clock,
};

pub const PhaseBias = struct { cycles: f64, discontinuity: u2 };

const OrbitBlock = struct { validity: Validity, sats: []const Orbit };
const ClockFullBlock = struct { validity: Validity, multipliers: []const u2, sats: []const Clock };
const ClockSubsetBlock = struct { validity: Validity, systems: []const ClockSubset };
const CodeBiasBlock = struct { validity: Validity, cells: []const ?f64 };
const PhaseBiasBlock = struct { validity: Validity, cells: []const ?PhaseBias };

pub const Message = struct {
    toh: u12,
    mask_id: u5,
    iod_set_id: u5,
    mask: ?Mask = null,
    orbit: ?OrbitBlock = null,
    clock_full: ?ClockFullBlock = null,
    clock_subset: ?ClockSubsetBlock = null,
    code_bias: ?CodeBiasBlock = null,
    phase_bias: ?PhaseBiasBlock = null,
};

const radial_lsb: f64 = 0.0025;
const track_lsb: f64 = 0.0080;
const clock_lsb: f64 = 0.0025;
const code_bias_lsb: f64 = 0.02;
const phase_bias_lsb: f64 = 0.01;
pub const phase_bias_max: f64 = 1023 * phase_bias_lsb;

fn quantize(value: f64, lsb: f64, comptime bits: u7, reserve_max: i64) ?@Int(.signed, bits) {
    const limit = std.math.maxInt(@Int(.signed, bits));
    return @intCast(scaling.roundWithin(value / lsb, -limit, limit - reserve_max) orelse return null);
}

fn notAvailable(comptime bits: u7) @Int(.signed, bits) {
    return std.math.minInt(@Int(.signed, bits));
}

fn writeQuantized(w: *BoundedWriter, comptime bits: u7, value: ?f64, lsb: f64, reserve_max: i64) error{BufferFull}!void {
    const q = if (value) |v| quantize(v, lsb, bits, reserve_max) orelse notAvailable(bits) else notAvailable(bits);
    try w.writeBits(bits, q);
}

fn writeMask(w: *BoundedWriter, mask: Mask) Error!void {
    if (mask.systems.len < 1 or mask.systems.len > max_systems) return error.Layout;
    try w.writeUnsigned(4, mask.systems.len);
    for (mask.systems) |s| {
        try w.writeBits(4, @intFromEnum(s.gnss));
        for (s.sats) |b| try w.writeBits(1, b);
        for (s.sigs) |b| try w.writeBits(1, b);
        try w.writeBits(1, s.cells != null);
        if (s.cells) |c| {
            if (c.len != s.satCount() * s.sigCount()) return error.Layout;
            for (c) |b| try w.writeBits(1, b);
        }
        try w.writeBits(3, s.nav_message);
    }
    try w.writeBits(6, 0);
}

fn writeOrbit(w: *BoundedWriter, mask: Mask, block: OrbitBlock) Error!void {
    if (block.sats.len != mask.satCount()) return error.Layout;
    try w.writeBits(4, @intFromEnum(block.validity));
    var i: usize = 0;
    for (mask.systems) |s| {
        for (0..s.satCount()) |_| {
            const o = block.sats[i];
            i += 1;
            switch (s.gnss) {
                .gps => try w.writeUnsigned(8, o.iod),
                .galileo => try w.writeUnsigned(10, o.iod),
            }
            try writeQuantized(w, 13, o.radial_m, radial_lsb, 0);
            try writeQuantized(w, 12, o.in_track_m, track_lsb, 0);
            try writeQuantized(w, 12, o.cross_m, track_lsb, 0);
        }
    }
}

fn clockScale(multiplier: u2) f64 {
    return clock_lsb * @as(f64, @floatFromInt(@as(u3, multiplier) + 1));
}

pub fn clockFits(value_m: f64, multiplier: u2) bool {
    return quantize(value_m, clockScale(multiplier), 13, 1) != null;
}

const clock_do_not_use = 4095;

fn writeClock(w: *BoundedWriter, c: Clock, multiplier: u2) error{BufferFull}!void {
    switch (c) {
        .value_m => |v| try writeQuantized(w, 13, v, clockScale(multiplier), 1),
        .not_available => try w.writeBits(13, notAvailable(13)),
        .do_not_use => try w.writeBits(13, clock_do_not_use),
    }
}

fn writeClockFull(w: *BoundedWriter, mask: Mask, block: ClockFullBlock) Error!void {
    if (block.multipliers.len != mask.systems.len or block.sats.len != mask.satCount()) return error.Layout;
    try w.writeBits(4, @intFromEnum(block.validity));
    for (block.multipliers) |m| try w.writeBits(2, m);
    var i: usize = 0;
    for (mask.systems, block.multipliers) |s, m| {
        for (0..s.satCount()) |_| {
            try writeClock(w, block.sats[i], m);
            i += 1;
        }
    }
}

fn writeClockSubset(w: *BoundedWriter, mask: Mask, block: ClockSubsetBlock) Error!void {
    if (block.systems.len < 1 or block.systems.len > max_systems) return error.Layout;
    try w.writeBits(4, @intFromEnum(block.validity));
    try w.writeUnsigned(4, block.systems.len);
    for (block.systems) |sub| {
        const masked = for (mask.systems) |s| {
            if (s.gnss == sub.gnss) break s;
        } else return error.Layout;
        if (sub.selected.len != masked.satCount()) return error.Layout;
        if (sub.values.len != std.mem.countScalar(bool, sub.selected, true)) return error.Layout;
        try w.writeBits(4, @intFromEnum(sub.gnss));
        try w.writeBits(2, sub.multiplier);
        for (sub.selected) |b| try w.writeBits(1, b);
        for (sub.values) |v| try writeClock(w, v, sub.multiplier);
    }
}

fn writeCodeBias(w: *BoundedWriter, mask: Mask, block: CodeBiasBlock) Error!void {
    if (block.cells.len != mask.cellCount()) return error.Layout;
    try w.writeBits(4, @intFromEnum(block.validity));
    for (block.cells) |c| try writeQuantized(w, 11, c, code_bias_lsb, 0);
}

fn writePhaseBias(w: *BoundedWriter, mask: Mask, block: PhaseBiasBlock) Error!void {
    if (block.cells.len != mask.cellCount()) return error.Layout;
    try w.writeBits(4, @intFromEnum(block.validity));
    for (block.cells) |c| {
        try writeQuantized(w, 11, if (c) |p| p.cycles else null, phase_bias_lsb, 0);
        try w.writeBits(2, if (c) |p| p.discontinuity else 0);
    }
}

pub fn encode(m: *const Message, context: ?Mask, bits: *MessageBits) Error!usize {
    const mask = m.mask orelse context orelse return error.Layout;
    var w: BoundedWriter = .init(&bits.words);
    try w.writeBits(12, m.toh);
    try w.writeBits(1, m.mask != null);
    try w.writeBits(1, m.orbit != null);
    try w.writeBits(1, m.clock_full != null);
    try w.writeBits(1, m.clock_subset != null);
    try w.writeBits(1, m.code_bias != null);
    try w.writeBits(1, m.phase_bias != null);
    try w.writeBits(4, 0);
    try w.writeBits(5, m.mask_id);
    try w.writeBits(5, m.iod_set_id);
    if (m.mask) |mk| try writeMask(&w, mk);
    if (m.orbit) |b| try writeOrbit(&w, mask, b);
    if (m.clock_full) |b| try writeClockFull(&w, mask, b);
    if (m.clock_subset) |b| try writeClockSubset(&w, mask, b);
    if (m.code_bias) |b| try writeCodeBias(&w, mask, b);
    if (m.phase_bias) |b| try writePhaseBias(&w, mask, b);
    return w.bitsWritten();
}
