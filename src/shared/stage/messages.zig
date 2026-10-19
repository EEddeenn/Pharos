const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const bundle = @import("../bundle.zig");
const Broadcast = @import("ionosphere.zig").Broadcast;
const frame = @import("../codec.zig").frame;
const field = @import("../codec.zig").field;
pub const inputs = @import("messages/inputs.zig");
const lnav = gnss.gps.lnav;
const cnav = gnss.gps.cnav;
const cnav2 = gnss.gps.cnav2;
const inav = gnss.galileo.inav;
const fnav = gnss.galileo.fnav;
const cnav_has = gnss.galileo.cnav;
const d1d2 = gnss.bds.d1d2;
const bcnav1 = gnss.bds.bcnav1;
const bcnav2 = gnss.bds.bcnav2;
const bcnav3 = gnss.bds.bcnav3;
const ppp_b2b = gnss.bds.ppp_b2b;
const gnav = gnss.glonass.gnav;
const spec = gnss.spec;
const Signal = core.types.Signal;
const NavFamily = core.types.NavFamily;
const GpsTime = core.time.GpsTime;

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

pub fn Set(comptime family: NavFamily) type {
    return coderOf(family).Set;
}

const max_frame_bits = blk: {
    var most: usize = 0;
    for (std.enums.values(NavFamily)) |family| most = @max(most, coderOf(family).bits_per_frame);
    break :blk most;
};
pub const FrameBits = frame.Bits(max_frame_bits);

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

        fn requireData(self: @This(), prn: u8) MissingData!void {
            if (@hasDecl(coder, "requireData")) try coder.requireData(self.set, prn);
        }

        fn setCycle(prn: u8, index: i64) i64 {
            return if (@hasDecl(coder, "setCycle")) coder.setCycle(prn, index) else index;
        }
    };
}

pub const MissingData = error{ MissingEarthOrientation, MissingTimeOffset, MissingUtcParameters };

pub const Failure = MissingData || error{MessageSet};

pub fn reason(e: Failure) []const u8 {
    return switch (e) {
        error.MessageSet => "the bundle's supplied message content cannot be encoded into the message sets of the listed signals",
        error.MissingEarthOrientation => "B-CNAV3 on B2b (a BDS record) and GNAV on G1/G2 (any system's) require an available EOP record in the navigation data",
        error.MissingTimeOffset => "GLONASS navigation requires available, constant GLUT and GLGP time offsets",
        error.MissingUtcParameters => "the selected BeiDou navigation message requires available, encodable BDUT parameters",
    };
}

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

    pub fn hasFrames(self: MessageSet, prn: u8) bool {
        return switch (self) {
            inline else => |f| f.set.hasRecord(prn),
        };
    }

    pub fn requireData(self: MessageSet, prn: u8) MissingData!void {
        switch (self) {
            inline else => |f| try f.requireData(prn),
        }
    }

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

comptime {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(Signal)) |signal| {
        const s = spec.get(signal);
        var sats = signal.system().satellites();
        while (sats.next()) |sat| {
            const family = gnss.payload.familyFor(sat, signal);
            if (family.system() != signal.system()) @compileError("the family of " ++ @tagName(signal) ++ " belongs to another system");
            const frame_ms = switch (family) {
                inline else => |f| @FieldType(MessageSet, @tagName(f)).frameMs(signal),
            };
            if (s.frame.frame_length_ms != frame_ms) @compileError("the frame length of " ++ @tagName(signal) ++ " is not its coder's");
        }
        if (s.geo_frame) |geo| if (geo.frame_length_ms != d1d2.d2_frame_ms) @compileError("the GEO frame length of " ++ @tagName(signal) ++ " is not the D2 subframe");
    }
}

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

fn nullDefault(comptime T: type) *const anyopaque {
    const value: T = null;
    return @ptrCast(&value);
}

fn OptionalPtr(comptime S: type) type {
    return ?*const S;
}

pub const Snapshot = Sets(OptionalPtr);

pub fn forChannel(snapshot: Snapshot, payload: *const gnss.payload.Payload, key: core.types.ChannelKey) ?MessageSet {
    return forFamily(snapshot, payload.familyOf(key.sat, key.signal) orelse return null, key.signal);
}

pub fn forFamily(snapshot: Snapshot, family: NavFamily, signal: Signal) ?MessageSet {
    switch (family) {
        inline else => |f| {
            const set = @field(snapshot, @tagName(f)) orelse return null;
            return @unionInit(MessageSet, @tagName(f), @FieldType(MessageSet, @tagName(f)).of(set, signal));
        },
    }
}

pub const PublicationTarget = enum { gps, cnav2, inav, d2 };
pub const PreparationFailure = struct { target: PublicationTarget, publication: gnss.publication.Failure };

fn preparePublications(comptime Prepared: type, arena: std.mem.Allocator, raw: anytype, target: PublicationTarget, failure: *PreparationFailure) gnss.publication.PrepareError![]const gnss.publication.Publication(Prepared) {
    var publication: gnss.publication.Failure = undefined;
    return gnss.publication.prepare(Prepared, arena, raw, &publication) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPublication => {
            failure.* = .{ .target = target, .publication = publication };
            return error.InvalidPublication;
        },
    };
}

pub const Messages = struct {
    gps: []const gnss.gps.messages.Publication = &.{},
    cnav2: []const cnav2.publications.PreparedPublication = &.{},
    inav: []const inav.ism.PreparedPublication = &.{},
    d2: []const d1d2.augmentation.PreparedPublication = &.{},
    configuration: [63]u3 = @splat(0),
    cnav2_configuration: ?*const cnav2.publications.Payload = null,

    pub fn prepare(arena: std.mem.Allocator, source: bundle.messages.Messages, kinds: std.EnumSet(NavFamily), start: GpsTime, failure: *PreparationFailure) gnss.publication.PrepareError!Messages {
        const gps = kinds.contains(.lnav) or kinds.contains(.cnav);
        const codes = gnss.gps.allocation.configurationAt(start);
        var out: Messages = .{
            .gps = if (gps) try preparePublications(gnss.gps.messages.Sources, arena, source.gps, .gps, failure) else &.{},
            .cnav2 = if (kinds.contains(.cnav2)) try preparePublications(cnav2.publications.Content, arena, source.gps, .cnav2, failure) else &.{},
            .inav = if (kinds.contains(.inav)) try preparePublications(inav.ism.Content, arena, source.inav, .inav, failure) else &.{},
            .d2 = if (kinds.contains(.d1d2)) try preparePublications(d1d2.augmentation.Prepared, arena, source.d2, .d2, failure) else &.{},
            .configuration = codes,
        };
        if (kinds.contains(.cnav2)) {
            const page = try arena.create(cnav2.publications.Payload);
            page.* = cnav2.publications.configurationPage(&codes);
            out.cnav2_configuration = page;
        }
        return out;
    }
};

pub const Sources = struct { has: ?cnav_has.PageSource = null, ppp_b2b: ?ppp_b2b.FrameSource = null, d2: ?d1d2.augmentation.Source = null, dc: ?gnss.gps.dc.Source = null };

pub fn build(comptime family: NavFamily, out: *Set(family), b: *const bundle.Bundle, broadcast: *const Broadcast, messages: Messages, sources: Sources, t: GpsTime) field.Error!void {
    return out.build(switch (family) {
        .lnav => inputs.lnav(b, broadcast, messages.gps, messages.configuration, t),
        .cnav => inputs.cnav(b, broadcast, messages.gps, sources.dc, t),
        .cnav2 => inputs.cnav2(b, broadcast, messages.cnav2, messages.cnav2_configuration, sources.dc, t),
        .inav => inputs.inav(b, broadcast, messages.inav, t),
        .fnav => inputs.fnav(b, broadcast, t),
        .cnav_has => .{ .pages = sources.has },
        .d1d2 => inputs.d1d2(b, broadcast, sources.d2, t),
        .bcnav1, .bcnav2, .bcnav3 => inputs.bcnav(b, broadcast, family, t),
        .ppp_b2b => .{ .frames = sources.ppp_b2b },
        .gnav => inputs.gnav(b, t),
    });
}
