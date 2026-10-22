pub const Prns = struct {
    list: [32]u6 = undefined,
    len: u6 = 0,

    pub fn group(self: *const Prns, size: usize, ordinal: i64) []const u6 {
        const groups: i64 = @intCast((self.len + size - 1) / size);
        const first = size * @as(usize, @intCast(@mod(ordinal, groups)));
        return self.list[first..@min(first + size, self.len)];
    }

    pub fn at(self: *const Prns, ordinal: i64) u6 {
        return self.list[@intCast(@mod(ordinal, @as(i64, self.len)))];
    }
};
