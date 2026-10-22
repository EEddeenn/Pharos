const std = @import("std");
const ppp_b2b_content = @import("domain/messages/bds/ppp_b2b/content");
const supplier = @import("domain/messages/supplier");
const b2b = @import("domain/messages/bds/b2b_frame");
const Common = ppp_b2b_content.Common;
const common_reserved_bits = ppp_b2b_content.common_reserved_bits;
const OrbitEntry = ppp_b2b_content.OrbitEntry;
const ClockEntry = ppp_b2b_content.ClockEntry;
const content_bits = ppp_b2b_content.content_bits;
const common_bits = ppp_b2b_content.common_bits;
const combination_header_bits = ppp_b2b_content.combination_header_bits;
const orbit_entry_bits = ppp_b2b_content.orbit_entry_bits;
const Type = ppp_b2b_content.Type;
const mask_clock_header_bits = ppp_b2b_content.mask_clock_header_bits;
const clock_entry_bits = ppp_b2b_content.clock_entry_bits;
const slot_clock_entry_bits = ppp_b2b_content.slot_clock_entry_bits;
const Content = ppp_b2b_content.Content;
const Bias = ppp_b2b_content.Bias;
const DcbEntry = ppp_b2b_content.DcbEntry;
const DcbCount = ppp_b2b_content.DcbCount;
const BiasCount = ppp_b2b_content.BiasCount;
const CombinationClockCount = ppp_b2b_content.CombinationClockCount;
const CombinationOrbitCount = ppp_b2b_content.CombinationOrbitCount;
const BitWriter = @import("base/binary/bit_writer").BitWriter;
const crc24q = @import("base/binary/crc").crc24q;
pub const Message = b2b.Message;
pub const frame_ms = 1000;
pub const bits_per_frame = b2b.bits_per_frame;
pub const Frame = b2b.Frame;
pub const null_message: Message = blk: {
    @setEvalBranchQuota(20_000);
    break :blk encode(.null_message, {});
};

pub const Error = error{PayloadTooLarge};

pub const MessageSource = supplier.Supplier(i64, ppp_b2b_content.Transmission);
pub const Set = struct {
    messages: ?MessageSource = null,

    pub const Inputs = struct { messages: ?MessageSource = null };

    pub fn init(input: Inputs) Set {
        return .{ .messages = input.messages };
    }
};

pub fn encode(comptime kind: Type, payload: @FieldType(Content, @tagName(kind))) if (kind == .combination_mask or kind == .combination_slot) Error!Message else Message {
    switch (kind) {
        .combination_mask, .combination_slot => {
            const clocks = if (payload.clock) |c| c.entries.len else 0;
            const orbits = if (payload.orbit) |o| o.entries.len else 0;
            try requireCombinationRoom(clocks, orbits, if (kind == .combination_mask) mask_clock_header_bits else common_bits, if (kind == .combination_mask) clock_entry_bits else slot_clock_entry_bits);
        },
        else => {},
    }

    var out: Message = .{};
    var w = out.writer();
    writeContent(&w, @unionInit(Content, @tagName(kind), payload));
    w.skip(content_bits - w.bitsWritten());
    w.writeBits(24, crc24q.ofBits(&out.words, content_bits));
    return out;
}

pub fn encodeFrame(m: *const Message, prn: u8, available: bool) Frame {
    var out = b2b.encodeFrame(m, prn);
    out.set(22, @intFromBool(!available));
    return out;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (set.messages) |source| if (source.read(index)) |content| return encodeFrame(&content.message, prn, content.available);
    return encodeFrame(&null_message, prn, false);
}

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

fn writeClockEntry(w: *BitWriter, e: ClockEntry) void {
    w.writeBits(3, e.iod_corr);
    w.writeBits(15, e.c0 orelse std.math.minInt(i15));
}

fn requireCombinationRoom(clocks: usize, orbits: usize, comptime clock_header_bits: usize, comptime clock_bits: usize) Error!void {
    var remaining: usize = content_bits - combination_header_bits;
    if (clocks > 0) {
        if (clocks > (remaining - clock_header_bits) / clock_bits) return error.PayloadTooLarge;
        remaining -= clock_header_bits + clocks * clock_bits;
    }
    if (orbits > 0 and (remaining < common_bits or orbits > (remaining - common_bits) / orbit_entry_bits)) return error.PayloadTooLarge;
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
