pub const bch51 = Systematic(8, 51, &.{ 0, 1, 2, 3, 4, 7 });
pub const bch21 = Systematic(6, 21, &.{ 0, 1, 2, 4 });
pub fn Systematic(comptime k: u8, comptime n: u8, comptime taps: []const u8) type {
    return struct {
        pub const Message = @Int(.unsigned, k);
        const Codeword = @Int(.unsigned, n);

        pub fn codeword(message: Message) Codeword {
            var bits: [n]u1 = undefined;
            for (0..k) |i| bits[i] = @truncate(message >> @intCast(k - 1 - i));
            for (k..n) |i| {
                var fb: u1 = 0;
                inline for (taps) |t| fb ^= bits[i - k + t];
                bits[i] = fb;
            }
            var out: Codeword = 0;
            for (bits) |b| out = (out << 1) | b;
            return out;
        }
    };
}
