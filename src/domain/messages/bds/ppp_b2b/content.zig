const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const scaling = @import("base/binary/scaling");
const b2b = @import("domain/messages/bds/b2b_frame");
pub const content_bits = b2b.content_bits;
pub const Type = enum(u6) {
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
pub const DcbCount = u5;
pub const BiasCount = u4;
pub const common_reserved_bits = 4;
pub const common_bits = @bitSizeOf(@FieldType(Common, "epoch_s")) + common_reserved_bits + @bitSizeOf(@FieldType(Common, "iod_ssr"));
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
pub const CombinationClockCount = u5;
pub const CombinationOrbitCount = u3;
pub const combination_header_bits = @bitSizeOf(Type) + @bitSizeOf(CombinationClockCount) + @bitSizeOf(CombinationOrbitCount);
pub const mask_clock_header_bits = common_bits + @bitSizeOf(@FieldType(ClockBlock, "iodp")) + @bitSizeOf(@FieldType(ClockBlock, "slot_s"));
pub const clock_entry_bits = @bitSizeOf(@FieldType(ClockEntry, "iod_corr")) + @bitSizeOf(@typeInfo(@FieldType(ClockEntry, "c0")).optional.child);
pub const slot_clock_entry_bits = @bitSizeOf(@FieldType(SlotClock, "slot")) + clock_entry_bits;
pub const orbit_entry_bits = @bitSizeOf(@FieldType(OrbitEntry, "slot")) +
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

pub const Mode = struct { mode: u4, signal: gnss_types.Signal, component: gnss_types.Component };
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

pub const empty_orbit: OrbitEntry = .{ .slot = 0, .iodn = 0, .iod_corr = 0, .correction = .{ .radial = 0, .along = 0, .cross = 0 }, .ura = .{ .class = 0, .value = 0 } };

pub const Transmission = struct { message: b2b.Message, available: bool };

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
