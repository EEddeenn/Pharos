const bitwriter = @import("../../codec.zig").bitwriter;

pub const max_len = 288;
pub const degree: u8 = 0o370;

pub fn allowed(c: u8) bool {
    return switch (c) {
        'A'...'Z', '0'...'9', '+', '-', '.', '\'', degree, '/', ' ', ':', '"' => true,
        else => false,
    };
}

pub fn valid(t: []const u8) bool {
    if (t.len == 0 or t.len > max_len) return false;
    for (t) |c| if (!allowed(c)) return false;
    return true;
}

pub fn Page(comptime length: usize) type {
    return struct { number: u4, characters: [length]u8 };
}

pub fn page(t: []const u8, comptime length: usize, ordinal: i64) Page(length) {
    const count: i64 = @intCast((t.len + length - 1) / length);
    const k: usize = @intCast(@mod(ordinal, count));
    var out: Page(length) = .{ .number = @intCast(k), .characters = @splat(' ') };
    const rest = t[k * length ..];
    const n = @min(rest.len, length);
    @memcpy(out.characters[0..n], rest[0..n]);
    return out;
}

pub fn write(w: *bitwriter.BitWriter, characters: []const u8) void {
    for (characters) |c| w.writeBits(8, c);
}
