const std = @import("std");

pub const System = enum(u2) {
    gps = 0,
    bds = 1,
    gal = 2,
    glo = 3,

    pub const all = std.enums.values(System);

    pub fn capacity(self: System) u8 {
        return switch (self) {
            .gps => 32,
            .bds => 63,
            .gal => 36,
            .glo => 24,
        };
    }

    pub fn satellites(self: System) Satellites {
        return .{ .system = self };
    }

    const Satellites = struct {
        system: System,
        index: u8 = 0,

        pub fn next(self: *Satellites) ?SatId {
            if (self.index == self.system.capacity()) return null;
            defer self.index += 1;
            return SatId.at(self.system, self.index);
        }
    };

    pub const words: std.EnumArray(System, []const u8) = .init(.{ .gps = "GPS", .bds = "BDS", .gal = "Galileo", .glo = "GLONASS" });

    pub fn name(self: System) []const u8 {
        return words.get(self);
    }

    pub fn displayName(self: System) []const u8 {
        return switch (self) {
            .gps => "GPS",
            .bds => "BeiDou",
            .gal => "Galileo",
            .glo => "GLONASS",
        };
    }

    pub fn rinexLetter(self: System) u8 {
        return switch (self) {
            .gps => 'G',
            .bds => 'C',
            .gal => 'E',
            .glo => 'R',
        };
    }

    pub fn fromRinexLetter(letter: u8) ?System {
        return switch (letter) {
            'G' => .gps,
            'C' => .bds,
            'E' => .gal,
            'R' => .glo,
            else => null,
        };
    }
};

pub const SatId = packed struct(u8) {
    system: System,
    index: u6,

    pub const Error = error{PrnOutOfRange};

    pub fn fromPrn(system: System, number: u32) Error!SatId {
        if (number < 1 or number > system.capacity()) return error.PrnOutOfRange;
        return .{ .system = system, .index = @intCast(number - 1) };
    }

    pub fn at(system: System, index: usize) SatId {
        std.debug.assert(index < system.capacity());
        return .{ .system = system, .index = @intCast(index) };
    }

    pub fn valid(self: SatId) bool {
        return self.index < self.system.capacity();
    }

    pub fn prn(self: SatId) u8 {
        return @as(u8, self.index) + 1;
    }

    pub fn key(self: SatId) u8 {
        return @bitCast(self);
    }

    pub fn fromKey(k: u8) SatId {
        return @bitCast(k);
    }

    pub fn format(self: SatId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{c}{d:0>2}", .{ self.system.rinexLetter(), self.prn() });
    }

    pub fn parse(id: []const u8) ?SatId {
        if (id.len < 3) return null;
        const system = System.fromRinexLetter(id[0]) orelse return null;
        const number = std.fmt.parseInt(u32, std.mem.trim(u8, id[1..3], " "), 10) catch return null;
        return fromPrn(system, number) catch null;
    }
};

pub const FreqId = struct {
    k: i5,

    pub const Error = error{FreqIdOutOfRange};
    pub const min: i32 = -7;
    pub const max: i32 = 13;

    pub fn fromInt(k: i32) Error!FreqId {
        if (k < min or k > max) return error.FreqIdOutOfRange;
        return .{ .k = @intCast(k) };
    }

    pub fn valid(self: FreqId) bool {
        return self.k >= min and self.k <= max;
    }

    pub fn int(self: FreqId) i32 {
        return self.k;
    }
};

pub const Signal = enum(u8) {
    l1ca = 0,
    l1c = 1,
    l2c = 2,
    l5 = 3,
    b1c = 4,
    b1i = 5,
    b2i = 6,
    b3i = 7,
    b2a = 8,
    b2b = 9,
    e1 = 10,
    e5a = 11,
    e5b = 12,
    e6 = 13,
    g1 = 14,
    g2 = 15,

    pub const words: std.EnumArray(Signal, []const u8) = .init(.{
        .l1ca = "L1CA",
        .l1c = "L1C",
        .l2c = "L2C",
        .l5 = "L5",
        .b1c = "B1C",
        .b1i = "B1I",
        .b2i = "B2I",
        .b3i = "B3I",
        .b2a = "B2a",
        .b2b = "B2b",
        .e1 = "E1",
        .e5a = "E5a",
        .e5b = "E5b",
        .e6 = "E6",
        .g1 = "G1",
        .g2 = "G2",
    });

    pub fn system(self: Signal) System {
        return switch (self) {
            .l1ca, .l1c, .l2c, .l5 => .gps,
            .b1c, .b1i, .b2i, .b3i, .b2a, .b2b => .bds,
            .e1, .e5a, .e5b, .e6 => .gal,
            .g1, .g2 => .glo,
        };
    }

    pub fn name(self: Signal) []const u8 {
        return words.get(self);
    }
};

pub const Component = enum { data, pilot };

pub const ChannelKey = packed struct(u16) {
    sat: SatId,
    signal: Signal,

    pub fn init(sat: SatId, signal: Signal) ChannelKey {
        return .{ .sat = sat, .signal = signal };
    }

    pub fn format(self: ChannelKey, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{f} {s}", .{ self.sat, self.signal.name() });
    }
};

pub const SatSet = struct {
    bits: u64 = 0,

    pub const empty: SatSet = .{};

    pub fn insert(self: *SatSet, id: SatId) void {
        self.bits |= @as(u64, 1) << id.index;
    }

    pub fn contains(self: SatSet, id: SatId) bool {
        return (self.bits >> id.index) & 1 == 1;
    }

    pub fn merge(self: *SatSet, other: SatSet) void {
        self.bits |= other.bits;
    }

    pub fn count(self: SatSet) u8 {
        return @popCount(self.bits);
    }
};

pub const SampleRate = struct {
    khz: u32,

    pub fn fromKhz(khz: u32) SampleRate {
        return .{ .khz = khz };
    }

    pub fn hz(self: SampleRate) u64 {
        return @as(u64, self.khz) * 1000;
    }

    pub fn samplesPerEpoch(self: SampleRate) u32 {
        return self.khz;
    }

    pub fn mhz(self: SampleRate) f64 {
        return @as(f64, @floatFromInt(self.hz())) / 1e6;
    }
};

pub const Hz = struct {
    hz: i64,

    pub fn mhz(self: Hz) f64 {
        return @as(f64, @floatFromInt(self.hz)) / 1e6;
    }
};

pub const IqFormat = enum(u8) {
    iq2 = 0,
    iq4 = 1,
    iq8 = 2,
    iq16 = 3,

    pub const words: std.EnumArray(IqFormat, []const u8) = .init(.{ .iq2 = "IQ2", .iq4 = "IQ4", .iq8 = "IQ8", .iq16 = "IQ16" });

    pub fn name(self: IqFormat) []const u8 {
        return words.get(self);
    }

    pub fn bitsPerComponent(self: IqFormat) u8 {
        return switch (self) {
            .iq2 => 2,
            .iq4 => 4,
            .iq8 => 8,
            .iq16 => 16,
        };
    }

    pub fn bytesFor(self: IqFormat, samples: u32) usize {
        return switch (self) {
            .iq2 => blk: {
                std.debug.assert(samples % 2 == 0);
                break :blk @as(usize, samples) / 2;
            },
            .iq4 => samples,
            .iq8 => @as(usize, samples) * 2,
            .iq16 => @as(usize, samples) * 4,
        };
    }
};

pub const NavFamily = enum {
    lnav,
    cnav,
    cnav2,
    inav,
    fnav,
    cnav_has,
    d1d2,
    bcnav1,
    bcnav2,
    bcnav3,
    ppp_b2b,
    gnav,

    pub const words: std.EnumArray(NavFamily, []const u8) = .init(.{ .lnav = "LNAV", .cnav = "CNAV", .cnav2 = "CNAV-2", .inav = "I/NAV", .fnav = "F/NAV", .cnav_has = "C/NAV", .d1d2 = "D1/D2", .bcnav1 = "B-CNAV1", .bcnav2 = "B-CNAV2", .bcnav3 = "B-CNAV3", .ppp_b2b = "PPP-B2b", .gnav = "GNAV" });

    pub fn name(self: NavFamily) []const u8 {
        return words.get(self);
    }

    pub fn system(self: NavFamily) System {
        return switch (self) {
            .lnav, .cnav, .cnav2 => .gps,
            .inav, .fnav, .cnav_has => .gal,
            .d1d2, .bcnav1, .bcnav2, .bcnav3, .ppp_b2b => .bds,
            .gnav => .glo,
        };
    }
};
