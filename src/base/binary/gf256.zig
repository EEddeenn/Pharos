const Gf256 = @import("base/binary/gf").Gf(8, rs_poly);
const rs_poly = 0x11d;
const mul = Gf256.mul;

pub fn Encoder(comptime parity_len: usize) type {
    return struct {
        const gen: [parity_len + 1]u8 = generator(parity_len);

        pub fn parity(info: []const u8, out: *[parity_len]u8) void {
            var rem: [parity_len]u8 = @splat(0);
            for (info) |byte| {
                const feedback = byte ^ rem[0];
                @memmove(rem[0 .. parity_len - 1], rem[1..]);
                rem[parity_len - 1] = 0;
                if (feedback != 0) {
                    for (0..parity_len) |k| rem[k] ^= mul(feedback, gen[k + 1]);
                }
            }
            out.* = rem;
        }
    };
}

fn generator(comptime parity_len: usize) [parity_len + 1]u8 {
    @setEvalBranchQuota(4_000_000);
    var g: [parity_len + 1]u8 = @splat(0);
    g[0] = 1;
    var degree: usize = 0;
    for (1..parity_len + 1) |i| {
        const root = Gf256.tables.exp[i];
        var j = degree + 1;
        while (j > 0) : (j -= 1) g[j] = g[j - 1] ^ mul(g[j], root);
        g[0] = mul(g[0], root);
        degree += 1;
    }
    var out: [parity_len + 1]u8 = undefined;
    for (0..parity_len + 1) |k| out[k] = g[parity_len - k];
    return out;
}
