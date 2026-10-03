const frame = @import("../../../codec.zig").frame;

const data_symbols = 170;
const time_mark_symbols = 30;

const check_rows = [7][]const u8{
    &.{ 9, 10, 12, 13, 15, 17, 19, 20, 22, 24, 26, 28, 30, 32, 34, 35, 37, 39, 41, 43, 45, 47, 49, 51, 53, 55, 57, 59, 61, 63, 65, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84 },
    &.{ 9, 11, 12, 14, 15, 18, 19, 21, 22, 25, 26, 29, 30, 33, 34, 36, 37, 40, 41, 44, 45, 48, 49, 52, 53, 56, 57, 60, 61, 64, 65, 67, 68, 71, 72, 75, 76, 79, 80, 83, 84 },
    &.{ 10, 11, 12, 16, 17, 18, 19, 23, 24, 25, 26, 31, 32, 33, 34, 38, 39, 40, 41, 46, 47, 48, 49, 54, 55, 56, 57, 62, 63, 64, 65, 69, 70, 71, 72, 77, 78, 79, 80 },
    &.{ 13, 14, 15, 16, 17, 18, 19, 27, 28, 29, 30, 31, 32, 33, 34, 42, 43, 44, 45, 46, 47, 48, 49, 58, 59, 60, 61, 62, 63, 64, 65, 73, 74, 75, 76, 77, 78, 79, 80 },
    &.{ 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 81, 82, 83, 84 },
    &.{ 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65 },
    &.{ 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84 },
};

fn bitMask(comptime bit: u8) u85 {
    return @as(u85, 1) << (bit - 1);
}

const masks: [7]u85 = blk: {
    var m: [7]u85 = undefined;
    for (check_rows, 0..) |row, i| {
        m[i] = 0;
        for (row) |bit| m[i] |= bitMask(bit);
    }
    break :blk m;
};
const data_mask: u85 = blk: {
    var m: u85 = 0;
    for (9..85) |bit| m |= bitMask(@intCast(bit));
    break :blk m;
};

fn checkBits(data: u76) u8 {
    const string = @as(u85, data) << 8;
    var c: u8 = 0;
    inline for (masks, 0..) |m, i| c |= @as(u8, @as(u1, @truncate(@popCount(string & m)))) << i;
    const c8: u1 = @truncate(@popCount(string & data_mask) + @popCount(c));
    return c | (@as(u8, c8) << 7);
}

pub fn encodeString(data: u76) u85 {
    return (@as(u85, data) << 8) | checkBits(data);
}

const time_mark: u30 = 0x3E37_5096;
pub const symbols_per_string = 200;
pub const Frame = frame.Bits(symbols_per_string);

pub fn encode(string: u85) Frame {
    var out: Frame = .{};
    var previous: u1 = 0;
    for (0..85) |i| {
        const bit: u1 = @truncate(string >> @intCast(84 - i));
        const relative: u1 = if (i == 0) bit else previous ^ bit;
        previous = relative;
        out.set(2 * i, relative);
        out.set(2 * i + 1, relative ^ 1);
    }
    for (0..time_mark_symbols) |j| out.set(data_symbols + j, @truncate(time_mark >> @intCast(time_mark_symbols - 1 - j)));
    return out;
}
