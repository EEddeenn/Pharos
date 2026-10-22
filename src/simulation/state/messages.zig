const std = @import("std");
const time = @import("domain/time/gps");
const gnss_types = @import("domain/gnss_types");
const signal_payload = @import("domain/signals/payload");
const signal_catalog = @import("domain/signals/catalog");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const differential = @import("domain/messages/gps/differential");
const lnav = @import("domain/messages/gps/lnav/root");
const cnav = @import("domain/messages/gps/cnav/root");
const cnav2 = @import("domain/messages/gps/cnav2/root");
const inav = @import("domain/messages/galileo/inav/root");
const fnav = @import("domain/messages/galileo/fnav/root");
const cnav_has = @import("domain/messages/galileo/cnav");
const d1d2 = @import("domain/messages/bds/d1d2/root");
const bcnav1 = @import("domain/messages/bds/bcnav1/root");
const bcnav2 = @import("domain/messages/bds/bcnav2/root");
const bcnav3 = @import("domain/messages/bds/bcnav3/root");
const ppp_b2b = @import("domain/messages/bds/ppp_b2b/root");
const gnav = @import("domain/messages/glonass/gnav/root");
const frame = @import("base/binary/bits");
const inputs = @import("simulation/state/messages/inputs");

const GpsTime = time.GpsTime;

const Signal = gnss_types.Signal;
const NavFamily = gnss_types.NavFamily;

const max_frame_bits = blk: {
    var most: usize = 0;
    for (std.enums.values(NavFamily)) |family| most = @max(most, coderOf(family).bits_per_frame);
    break :blk most;
};
pub const FrameBits = frame.Bits(max_frame_bits);

pub const MessageSet = union(NavFamily) {
    lnav: Family(.lnav),
    cnav: Family(.cnav),
    cnav2: Family(.cnav2),
    inav: Family(.inav),
    fnav: Family(.fnav),
    cnav_has: Family(.cnav_has),
    d1d2: Family(.d1d2),
    bcnav1: Family(.bcnav1),
    bcnav2: Family(.bcnav2),
    bcnav3: Family(.bcnav3),
    ppp_b2b: Family(.ppp_b2b),
    gnav: Family(.gnav),

    pub fn frameBits(self: MessageSet, prn: u8, index: i64, out: *FrameBits) bool {
        out.* = .{};
        return switch (self) {
            inline else => |f| f.frameBits(prn, index, out),
        };
    }

    pub fn frameBitsAfter(self: MessageSet, previous: MessageSet, prn: u8, index: i64, out: *FrameBits) bool {
        out.* = .{};
        return switch (self) {
            inline else => |f, tag| f.frameBitsAfter(@field(previous, @tagName(tag)), prn, index, out),
        };
    }

    pub fn setCycle(self: MessageSet, prn: u8, index: i64) i64 {
        return switch (self) {
            inline else => |f| @TypeOf(f).setCycle(prn, index),
        };
    }
};

pub fn Set(comptime family: NavFamily) type {
    return coderOf(family).Set;
}

fn coderOf(comptime family: NavFamily) type {
    return switch (family) {
        .lnav => lnav,
        .cnav => cnav,
        .cnav2 => cnav2,
        .inav => inav,
        .fnav => fnav,
        .cnav_has => cnav_has,
        .d1d2 => d1d2,
        .bcnav1 => bcnav1,
        .bcnav2 => bcnav2,
        .bcnav3 => bcnav3,
        .ppp_b2b => ppp_b2b,
        .gnav => gnav,
    };
}

fn Family(comptime family: NavFamily) type {
    const coder = coderOf(family);
    return struct {
        set: *const Set(family),
        carrier: Carrier,

        const Carrier = if (@hasDecl(coder, "Carrier")) coder.Carrier else void;

        fn of(set: *const Set(family), signal: Signal) @This() {
            return .{ .set = set, .carrier = if (Carrier == void) {} else Carrier.of(signal) };
        }

        fn frameMs(signal: Signal) u32 {
            return if (Carrier == void) coder.frame_ms else Carrier.of(signal).frameMs();
        }

        fn frameBits(self: @This(), prn: u8, index: i64, out: *FrameBits) bool {
            const f = (if (Carrier == void) coder.buildFrame(self.set, prn, index) else coder.buildFrame(self.set, prn, index, self.carrier)) orelse return false;
            out.words[0..f.words.len].* = f.words;
            return true;
        }

        fn frameBitsAfter(self: @This(), previous: @This(), prn: u8, index: i64, out: *FrameBits) bool {
            if (@hasDecl(coder, "buildFrameAfter")) {
                const f = coder.buildFrameAfter(self.set, previous.set, prn, index, self.carrier) orelse return false;
                out.words[0..f.words.len].* = f.words;
                return true;
            }
            return self.frameBits(prn, index, out);
        }

        fn setCycle(prn: u8, index: i64) i64 {
            return if (@hasDecl(coder, "setCycle")) coder.setCycle(prn, index) else index;
        }
    };
}

comptime {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(Signal)) |signal| {
        const s = signal_catalog.get(signal);
        var sats = signal.system().satellites();
        while (sats.next()) |sat| {
            const family = signal_payload.familyFor(sat, signal);
            if (family.system() != signal.system()) @compileError("the family of " ++ @tagName(signal) ++ " belongs to another system");
            const frame_ms = switch (family) {
                inline else => |f| @FieldType(MessageSet, @tagName(f)).frameMs(signal),
            };
            if (s.frame.frame_length_ms != frame_ms) @compileError("the frame length of " ++ @tagName(signal) ++ " is not its coder's");
        }
        if (s.geo_frame) |geo| if (geo.frame_length_ms != d1d2.d2_frame_ms) @compileError("the GEO frame length of " ++ @tagName(signal) ++ " is not the D2 subframe");
    }
}

// Borrowed from the current generation; a later rotation may reuse its storage.
pub const SetView = Sets(OptionalPtr);

pub const Suppliers = struct { has: ?cnav_has.PageSource = null, ppp_b2b: ?ppp_b2b.MessageSource = null, d2: ?augmentation.Source = null, dc: ?differential.Source = null };

pub fn Sets(comptime Wrap: fn (comptime type) type) type {
    const families = std.enums.values(NavFamily);
    var types: [families.len]type = undefined;
    var attrs: [families.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (families, 0..) |family, i| {
        types[i] = Wrap(Set(family));
        attrs[i] = .{ .default_value_ptr = if (@typeInfo(types[i]) == .optional) nullDefault(types[i]) else null };
    }
    return @Struct(.auto, null, @typeInfo(NavFamily).@"enum".field_names, &types, &attrs);
}

pub fn forChannel(view: SetView, allocation: *const signal_payload.Payload, key: gnss_types.ChannelKey) ?MessageSet {
    return forFamily(view, allocation.familyOf(key.sat, key.signal) orelse return null, key.signal);
}

pub fn initSet(comptime family: NavFamily, input: inputs.Inputs, suppliers: Suppliers, t: GpsTime) Set(family) {
    return Set(family).init(switch (family) {
        .lnav => inputs.lnav(input, t),
        .cnav => inputs.cnav(input, suppliers.dc, t),
        .cnav2 => inputs.cnav2(input, suppliers.dc, t),
        .inav => inputs.inav(input, t),
        .fnav => inputs.fnav(input, t),
        .cnav_has => .{ .pages = suppliers.has },
        .d1d2 => inputs.d1d2(input, suppliers.d2, t),
        .bcnav1, .bcnav2, .bcnav3 => inputs.bcnav(input, family, t),
        .ppp_b2b => .{ .messages = suppliers.ppp_b2b },
        .gnav => inputs.gnav(input, t),
    });
}

fn forFamily(view: SetView, family: NavFamily, signal: Signal) ?MessageSet {
    switch (family) {
        inline else => |f| {
            const set = @field(view, @tagName(f)) orelse return null;
            return @unionInit(MessageSet, @tagName(f), @FieldType(MessageSet, @tagName(f)).of(set, signal));
        },
    }
}

fn nullDefault(comptime T: type) *const anyopaque {
    const value: T = null;
    return @ptrCast(&value);
}

fn OptionalPtr(comptime S: type) type {
    return ?*const S;
}
