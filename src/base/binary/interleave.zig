pub fn Permutation(comptime n: usize) type {
    return struct {
        map: [n]u16,

        const Self = @This();

        pub fn apply(self: *const Self, comptime T: type, in: *const [n]T, out: *[n]T) void {
            for (out, self.map) |*o, i| o.* = in[i];
        }
    };
}

pub fn block(comptime a: usize, comptime b: usize) Permutation(a * b) {
    @setEvalBranchQuota(4 * a * b + 1000);
    var p: Permutation(a * b) = undefined;
    for (0..a) |i| for (0..b) |j| {
        p.map[i * b + j] = @intCast(j * a + i);
    };
    return p;
}
