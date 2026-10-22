const std = @import("std");

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
