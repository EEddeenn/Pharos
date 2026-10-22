pub fn Gf(comptime m: u4, comptime primitive: u16) type {
    return struct {
        const Element = @Int(.unsigned, m);
        const order = (1 << m) - 1;
        const Tables = struct { exp: [2 * order]Element, log: [order + 1]Element };

        pub const tables: Tables = blk: {
            @setEvalBranchQuota(20_000);
            var t: Tables = .{ .exp = undefined, .log = @splat(0) };
            var x: u16 = 1;
            for (0..order) |i| {
                t.exp[i] = @intCast(x);
                t.log[x] = @intCast(i);
                x <<= 1;
                if (x >> m != 0) x ^= primitive;
            }
            for (order..2 * order) |i| t.exp[i] = t.exp[i - order];
            break :blk t;
        };

        pub fn mul(a: Element, b: Element) Element {
            if (a == 0 or b == 0) return 0;
            return tables.exp[@as(u16, tables.log[a]) + tables.log[b]];
        }
    };
}
