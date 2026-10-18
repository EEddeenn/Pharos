const std = @import("std");
const types = @import("shared").core.types;
const GpsTime = @import("shared").core.time.GpsTime;
const Samples = @import("shared").bundle.scenario.Samples;

pub const max_len = 256;

fn formatName(format: types.IqFormat) ?[]const u8 {
    return switch (format) {
        .iq8 => "CS8",
        .iq16 => "CS16",
        .iq2, .iq4 => null,
    };
}

pub fn text(buffer: *[max_len]u8, samples: Samples, first: GpsTime) ?[]const u8 {
    const name = formatName(samples.format) orelse return null;
    const c = first.toCalendar();
    const ms: u32 = @intFromFloat(@floor(c.second * 1000.0));
    return std.mem.print(buffer,
        \\PROG = pharos-run
        \\TIME = {d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}
        \\FMT  = {s}
        \\F_S  = {d:.6}
        \\F_LO = {d:.6}
        \\IQ   = 2
        \\BITS = {d}
        \\
    , .{ @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, ms / 1000, ms % 1000, name, samples.sample_rate.mhz(), samples.center.mhz(), samples.format.bitsPerComponent() }) catch unreachable;
}
