pub fn Legendre(comptime p: u32) type {
    return struct {
        pub const table: [p]u1 = blk: {
            @setEvalBranchQuota(p * 4 + 1000);
            var t: [p]u1 = @splat(0);
            for (1..p) |i| t[(i * i) % p] = 1;
            break :blk t;
        };

        pub inline fn weil(k: u32, w: u32) u1 {
            return table[k] ^ table[(k + w) % p];
        }
    };
}
