const Lfsr = @import("base/binary/lfsr").Lfsr;

pub const chips = 511;

pub fn code(out: *[chips]u8) void {
    var r: Lfsr(9) = .{ .state = 0x1FF, .taps = (1 << 4) | (1 << 8) };
    for (out) |*chip| {
        chip.* = r.sum(1 << 6);
        _ = r.step();
    }
}
