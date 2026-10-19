const std = @import("std");
const types = @import("../../core.zig").types;
const BitWriter = @import("../../codec.zig").bitwriter.BitWriter;
const scaling = @import("../../codec.zig").scaling;
const crc24q = @import("../../codec.zig").crc24q;
const frame = @import("../../codec.zig").frame;
const b2b = @import("b2b.zig");

pub const Message = b2b.Message;
pub const content_bits = b2b.content_bits;
pub const frame_ms = 1000;
pub const bits_per_frame = b2b.bits_per_frame;
pub const Frame = b2b.Frame;

const Type = enum(u6) {
    mask = 1,
    orbit = 2,
    dcb = 3,
    clock = 4,
    ura = 5,
    combination_mask = 6,
    combination_slot = 7,
    null_message = 63,
};

pub const mask_slots = 255;
pub const bds_slot_base = 0;
pub const gps_slot_base = 63;
pub const galileo_slot_base = 100;

const radial_lsb: f64 = 0.0016;
const track_lsb: f64 = 0.0064;
const clock_lsb: f64 = 0.0016;
const dcb_lsb: f64 = 0.017;
const dcb_max = 2047;
pub const orbit_entries = 6;
pub const clock_entries = 23;
const ura_entries = 70;

pub const Common = struct { epoch_s: u17, iod_ssr: u2 };

pub const Ura = struct {
    class: u3,
    value: u3,
};

pub const OrbitCorrection = struct { radial: i15, along: i13, cross: i13 };

pub const OrbitEntry = struct {
    slot: u9,
    iodn: u10,
    iod_corr: u3,
    correction: OrbitCorrection,
    ura: Ura,
};

pub const Bias = struct { mode: u4, code: i12 };
pub const DcbEntry = struct { slot: u9, biases: []const Bias };
const DcbCount = u5;
const BiasCount = u4;
const common_reserved_bits = 4;
const common_bits = @bitSizeOf(@FieldType(Common, "epoch_s")) + common_reserved_bits + @bitSizeOf(@FieldType(Common, "iod_ssr"));
const dcb_header_bits = @bitSizeOf(Type) + common_bits + @bitSizeOf(DcbCount);
const dcb_entry_bits = @bitSizeOf(@FieldType(DcbEntry, "slot")) + @bitSizeOf(BiasCount);
const bias_bits = @bitSizeOf(@FieldType(Bias, "mode")) + @bitSizeOf(@FieldType(Bias, "code"));

pub const DcbPage = struct {
    common: Common,
    entries: [std.math.maxInt(DcbCount)]DcbEntry = undefined,
    len: DcbCount = 0,
    bits: usize = dcb_header_bits,

    pub fn append(self: *DcbPage, entry: DcbEntry) bool {
        if (self.len == self.entries.len or entry.biases.len > std.math.maxInt(BiasCount)) return false;
        const size = dcb_entry_bits + bias_bits * entry.biases.len;
        if (self.bits + size > content_bits) return false;
        self.entries[self.len] = entry;
        self.len += 1;
        self.bits += size;
        return true;
    }

    pub fn count(self: *const DcbPage) usize {
        return self.len;
    }
};

pub const ClockEntry = struct { iod_corr: u3, c0: ?i15 };
const SlotClock = struct { slot: u9, iod_corr: u3, c0: ?i15 };

const MaskMessage = struct { common: Common, iodp: u4, slots: [mask_slots]bool };
const OrbitMessage = struct { common: Common, entries: *const [orbit_entries]OrbitEntry };
const ClockMessage = struct { common: Common, iodp: u4, subtype: u5, entries: *const [clock_entries]ClockEntry };
const UraMessage = struct { common: Common, iodp: u4, subtype: u3, entries: *const [ura_entries]Ura };
const ClockBlock = struct { common: Common, iodp: u4, slot_s: u9, entries: []const ClockEntry };
const SlotClockBlock = struct { common: Common, entries: []const SlotClock };
const OrbitBlock = struct { common: Common, entries: []const OrbitEntry };
const CombinationMask = struct { clock: ?ClockBlock, orbit: ?OrbitBlock };
const CombinationSlot = struct { clock: ?SlotClockBlock, orbit: ?OrbitBlock };
const CombinationClockCount = u5;
const CombinationOrbitCount = u3;

const combination_header_bits = @bitSizeOf(Type) + @bitSizeOf(CombinationClockCount) + @bitSizeOf(CombinationOrbitCount);
const mask_clock_header_bits = common_bits + @bitSizeOf(@FieldType(ClockBlock, "iodp")) + @bitSizeOf(@FieldType(ClockBlock, "slot_s"));
const clock_entry_bits = @bitSizeOf(@FieldType(ClockEntry, "iod_corr")) + @bitSizeOf(@typeInfo(@FieldType(ClockEntry, "c0")).optional.child);
const slot_clock_entry_bits = @bitSizeOf(@FieldType(SlotClock, "slot")) + clock_entry_bits;
const orbit_entry_bits = @bitSizeOf(@FieldType(OrbitEntry, "slot")) +
    @bitSizeOf(@FieldType(OrbitEntry, "iodn")) +
    @bitSizeOf(@FieldType(OrbitEntry, "iod_corr")) +
    @bitSizeOf(@FieldType(OrbitCorrection, "radial")) +
    @bitSizeOf(@FieldType(OrbitCorrection, "along")) +
    @bitSizeOf(@FieldType(OrbitCorrection, "cross")) +
    @bitSizeOf(@FieldType(Ura, "class")) +
    @bitSizeOf(@FieldType(Ura, "value"));

pub const Content = union(Type) {
    mask: MaskMessage,
    orbit: OrbitMessage,
    dcb: DcbPage,
    clock: ClockMessage,
    ura: UraMessage,
    combination_mask: CombinationMask,
    combination_slot: CombinationSlot,
    null_message: void,
};

pub const Mode = struct { mode: u4, signal: types.Signal, component: types.Component };
pub const bds_modes = [_]Mode{
    .{ .mode = 0, .signal = .b1i, .component = .data },
    .{ .mode = 1, .signal = .b1c, .component = .data },
    .{ .mode = 2, .signal = .b1c, .component = .pilot },
    .{ .mode = 4, .signal = .b2a, .component = .data },
    .{ .mode = 5, .signal = .b2a, .component = .pilot },
    .{ .mode = 7, .signal = .b2b, .component = .data },
    .{ .mode = 12, .signal = .b3i, .component = .data },
};
pub const gps_modes = [_]Mode{
    .{ .mode = 0, .signal = .l1ca, .component = .data },
    .{ .mode = 4, .signal = .l1c, .component = .pilot },
    .{ .mode = 7, .signal = .l2c, .component = .pilot },
    .{ .mode = 8, .signal = .l2c, .component = .data },
    .{ .mode = 11, .signal = .l5, .component = .data },
    .{ .mode = 12, .signal = .l5, .component = .pilot },
};
pub const galileo_modes = [_]Mode{
    .{ .mode = 1, .signal = .e1, .component = .data },
    .{ .mode = 2, .signal = .e1, .component = .pilot },
    .{ .mode = 4, .signal = .e5a, .component = .pilot },
    .{ .mode = 5, .signal = .e5a, .component = .data },
    .{ .mode = 7, .signal = .e5b, .component = .data },
    .{ .mode = 8, .signal = .e5b, .component = .pilot },
    .{ .mode = 11, .signal = .e6, .component = .pilot },
};

const radial_max = 16383;
const track_max = 4095;
const clock_max = 16383;

pub fn orbitCorrection(radial_m: f64, along_m: f64, cross_m: f64) ?OrbitCorrection {
    return .{
        .radial = @intCast(scaling.roundWithin(radial_m / radial_lsb, -radial_max, radial_max) orelse return null),
        .along = @intCast(scaling.roundWithin(along_m / track_lsb, -track_max, track_max) orelse return null),
        .cross = @intCast(scaling.roundWithin(cross_m / track_lsb, -track_max, track_max) orelse return null),
    };
}

pub fn clockCode(c0_m: f64) ?i15 {
    return @intCast(scaling.roundWithin(c0_m / clock_lsb, -clock_max, clock_max) orelse return null);
}

pub fn dcbCode(bias_m: f64) ?i12 {
    return @intCast(scaling.roundWithin(bias_m / dcb_lsb, -dcb_max - 1, dcb_max) orelse return null);
}

pub const null_message: Message = blk: {
    @setEvalBranchQuota(20_000);
    break :blk encode(.null_message) catch unreachable;
};

fn writeCommon(w: *BitWriter, c: Common) void {
    w.writeBits(@bitSizeOf(@FieldType(Common, "epoch_s")), c.epoch_s);
    w.writeBits(common_reserved_bits, 0);
    w.writeBits(@bitSizeOf(@FieldType(Common, "iod_ssr")), c.iod_ssr);
}

fn writeOrbitEntry(w: *BitWriter, e: OrbitEntry) void {
    w.writeBits(9, e.slot);
    w.writeBits(10, e.iodn);
    w.writeBits(3, e.iod_corr);
    w.writeBits(15, e.correction.radial);
    w.writeBits(13, e.correction.along);
    w.writeBits(13, e.correction.cross);
    w.writeBits(3, e.ura.class);
    w.writeBits(3, e.ura.value);
}

pub const empty_orbit: OrbitEntry = .{ .slot = 0, .iodn = 0, .iod_corr = 0, .correction = .{ .radial = 0, .along = 0, .cross = 0 }, .ura = .{ .class = 0, .value = 0 } };

fn writeClockEntry(w: *BitWriter, e: ClockEntry) void {
    w.writeBits(3, e.iod_corr);
    w.writeBits(15, e.c0 orelse std.math.minInt(i15));
}

pub const Error = error{PayloadTooLarge};

fn requireCombinationRoom(clocks: usize, orbits: usize, comptime clock_header_bits: usize, comptime clock_bits: usize) Error!void {
    var remaining: usize = content_bits - combination_header_bits;
    if (clocks > 0) {
        if (clocks > (remaining - clock_header_bits) / clock_bits) return error.PayloadTooLarge;
        remaining -= clock_header_bits + clocks * clock_bits;
    }
    if (orbits > 0 and (remaining < common_bits or orbits > (remaining - common_bits) / orbit_entry_bits)) return error.PayloadTooLarge;
}

pub fn encode(content: Content) Error!Message {
    switch (content) {
        .combination_mask => |m| {
            const clocks = if (m.clock) |c| c.entries.len else 0;
            const orbits = if (m.orbit) |o| o.entries.len else 0;
            try requireCombinationRoom(clocks, orbits, mask_clock_header_bits, clock_entry_bits);
        },
        .combination_slot => |m| {
            const clocks = if (m.clock) |c| c.entries.len else 0;
            const orbits = if (m.orbit) |o| o.entries.len else 0;
            try requireCombinationRoom(clocks, orbits, common_bits, slot_clock_entry_bits);
        },
        else => {},
    }

    var out: Message = .{};
    var w = out.writer();
    writeContent(&w, content);
    w.skip(content_bits - w.bitsWritten());
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}

fn writeContent(w: *BitWriter, content: Content) void {
    w.writeBits(@bitSizeOf(Type), @backingInt(content));
    switch (content) {
        .mask => |m| {
            writeCommon(w, m.common);
            w.writeBits(4, m.iodp);
            for (m.slots) |b| w.writeBits(1, b);
        },
        .orbit => |m| {
            writeCommon(w, m.common);
            for (m.entries) |e| writeOrbitEntry(w, e);
        },
        .dcb => |m| {
            writeCommon(w, m.common);
            w.writeBits(@bitSizeOf(DcbCount), m.len);
            for (m.entries[0..m.len]) |e| {
                w.writeBits(@bitSizeOf(@FieldType(DcbEntry, "slot")), e.slot);
                w.writeBits(@bitSizeOf(BiasCount), @as(BiasCount, @intCast(e.biases.len)));
                for (e.biases) |b| {
                    w.writeBits(@bitSizeOf(@FieldType(Bias, "mode")), b.mode);
                    w.writeBits(@bitSizeOf(@FieldType(Bias, "code")), b.code);
                }
            }
        },
        .clock => |m| {
            writeCommon(w, m.common);
            w.writeBits(4, m.iodp);
            w.writeBits(5, m.subtype);
            for (m.entries) |e| writeClockEntry(w, e);
        },
        .ura => |m| {
            writeCommon(w, m.common);
            w.writeBits(4, m.iodp);
            w.writeBits(3, m.subtype);
            for (m.entries) |u| {
                w.writeBits(3, u.class);
                w.writeBits(3, u.value);
            }
        },
        .combination_mask => |m| {
            const numc = if (m.clock) |c| c.entries.len else 0;
            const numo = if (m.orbit) |o| o.entries.len else 0;
            w.writeBits(@bitSizeOf(CombinationClockCount), @as(CombinationClockCount, @intCast(numc)));
            w.writeBits(@bitSizeOf(CombinationOrbitCount), @as(CombinationOrbitCount, @intCast(numo)));
            if (m.clock) |c| if (numc > 0) {
                writeCommon(w, c.common);
                w.writeBits(4, c.iodp);
                w.writeBits(9, c.slot_s);
                for (c.entries) |e| writeClockEntry(w, e);
            };
            if (m.orbit) |o| if (numo > 0) {
                writeCommon(w, o.common);
                for (o.entries) |e| writeOrbitEntry(w, e);
            };
        },
        .combination_slot => |m| {
            const numc = if (m.clock) |c| c.entries.len else 0;
            const numo = if (m.orbit) |o| o.entries.len else 0;
            w.writeBits(@bitSizeOf(CombinationClockCount), @as(CombinationClockCount, @intCast(numc)));
            w.writeBits(@bitSizeOf(CombinationOrbitCount), @as(CombinationOrbitCount, @intCast(numo)));
            if (m.clock) |c| if (numc > 0) {
                writeCommon(w, c.common);
                for (c.entries) |e| {
                    w.writeBits(9, e.slot);
                    writeClockEntry(w, .{ .iod_corr = e.iod_corr, .c0 = e.c0 });
                }
            };
            if (m.orbit) |o| if (numo > 0) {
                writeCommon(w, o.common);
                for (o.entries) |e| writeOrbitEntry(w, e);
            };
        },
        .null_message => {},
    }
}

pub fn encodeFrame(m: *const Message, prn: u8, available: bool) Frame {
    var out = b2b.encodeFrame(m, prn);
    out.set(22, @intFromBool(!available));
    return out;
}

pub const FrameSource = frame.Source(bits_per_frame);

pub const Set = struct {
    frames: ?FrameSource = null,

    pub const Inputs = struct { frames: ?FrameSource = null };

    pub fn build(set: *Set, in: Inputs) void {
        set.* = .{ .frames = in.frames };
    }

    pub fn hasRecord(_: *const Set, _: u8) bool {
        return true;
    }
};

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (set.frames) |source| if (source.frame(prn, index)) |f| return f;
    return encodeFrame(&null_message, prn, false);
}
