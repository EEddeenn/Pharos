const std = @import("std");
const content = @import("domain/messages/galileo/has/content");
const bit_writer = @import("base/binary/bit_writer");
const scaling = @import("base/binary/scaling");
const Mask = content.Mask;
const OrbitBlock = content.OrbitBlock;
const Clock = content.Clock;
const ClockFullBlock = content.ClockFullBlock;
const ClockSubsetBlock = content.ClockSubsetBlock;
const CodeBiasBlock = content.CodeBiasBlock;
const PhaseBiasBlock = content.PhaseBiasBlock;
const Message = content.Message;
const MessageBits = @import("domain/messages/galileo/has/pages").MessageBits;
const BoundedWriter = bit_writer.BoundedWriter;
const Error = bit_writer.Error || error{Layout};
const max_systems = 15;
const radial_lsb: f64 = 0.0025;
const track_lsb: f64 = 0.0080;
const clock_lsb: f64 = 0.0025;
const code_bias_lsb: f64 = 0.02;
const phase_bias_lsb: f64 = 0.01;
pub const phase_bias_max: f64 = 1023 * phase_bias_lsb;

const clock_do_not_use = 4095;

pub fn clockFits(value_m: f64, multiplier: u2) bool {
    return quantize(value_m, clockScale(multiplier), 13, 1) != null;
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
    try w.writeBits(4, @as(u4, @intCast(mask.systems.len)));
    for (mask.systems) |s| {
        try w.writeBits(4, @backingInt(s.gnss));
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
    try w.writeBits(4, @backingInt(block.validity));
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

fn writeClock(w: *BoundedWriter, c: Clock, multiplier: u2) error{BufferFull}!void {
    switch (c) {
        .value_m => |v| try writeQuantized(w, 13, v, clockScale(multiplier), 1),
        .not_available => try w.writeBits(13, notAvailable(13)),
        .do_not_use => try w.writeBits(13, clock_do_not_use),
    }
}

fn writeClockFull(w: *BoundedWriter, mask: Mask, block: ClockFullBlock) Error!void {
    if (block.multipliers.len != mask.systems.len or block.sats.len != mask.satCount()) return error.Layout;
    try w.writeBits(4, @backingInt(block.validity));
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
    try w.writeBits(4, @backingInt(block.validity));
    try w.writeBits(4, @as(u4, @intCast(block.systems.len)));
    for (block.systems) |sub| {
        const masked = for (mask.systems) |s| {
            if (s.gnss == sub.gnss) break s;
        } else return error.Layout;
        if (sub.selected.len != masked.satCount()) return error.Layout;
        if (sub.values.len != std.mem.countScalar(bool, sub.selected, true)) return error.Layout;
        try w.writeBits(4, @backingInt(sub.gnss));
        try w.writeBits(2, sub.multiplier);
        for (sub.selected) |b| try w.writeBits(1, b);
        for (sub.values) |v| try writeClock(w, v, sub.multiplier);
    }
}

fn writeCodeBias(w: *BoundedWriter, mask: Mask, block: CodeBiasBlock) Error!void {
    if (block.cells.len != mask.cellCount()) return error.Layout;
    try w.writeBits(4, @backingInt(block.validity));
    for (block.cells) |c| try writeQuantized(w, 11, c, code_bias_lsb, 0);
}

fn writePhaseBias(w: *BoundedWriter, mask: Mask, block: PhaseBiasBlock) Error!void {
    if (block.cells.len != mask.cellCount()) return error.Layout;
    try w.writeBits(4, @backingInt(block.validity));
    for (block.cells) |c| {
        try writeQuantized(w, 11, if (c) |p| p.cycles else null, phase_bias_lsb, 0);
        try w.writeBits(2, if (c) |p| p.discontinuity else 0);
    }
}
