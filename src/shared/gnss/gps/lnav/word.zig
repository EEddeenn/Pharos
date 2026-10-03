const rows = [6][]const u8{
    &.{ 1, 2, 3, 5, 6, 10, 11, 12, 13, 14, 17, 18, 20, 23 },
    &.{ 2, 3, 4, 6, 7, 11, 12, 13, 14, 15, 18, 19, 21, 24 },
    &.{ 1, 3, 4, 5, 7, 8, 12, 13, 14, 15, 16, 19, 20, 22 },
    &.{ 2, 4, 5, 6, 8, 9, 13, 14, 15, 16, 17, 20, 21, 23 },
    &.{ 1, 3, 5, 6, 7, 9, 10, 14, 15, 16, 17, 18, 21, 22, 24 },
    &.{ 3, 5, 6, 8, 9, 10, 11, 13, 15, 19, 22, 23, 24 },
};
const uses_d29 = [6]bool{ true, false, true, false, false, true };

const masks: [6]u24 = blk: {
    var m: [6]u24 = undefined;
    for (rows, 0..) |row, i| {
        m[i] = 0;
        for (row) |bit| m[i] |= @as(u24, 1) << @intCast(24 - bit);
    }
    break :blk m;
};

fn parityBits(d: u24, d29s: u1, d30s: u1) u6 {
    var p: u6 = 0;
    for (masks, uses_d29) |m, from_d29| {
        const star = if (from_d29) d29s else d30s;
        const bit: u1 = @as(u1, @truncate(@popCount(d & m))) ^ star;
        p = (p << 1) | bit;
    }
    return p;
}

fn word(d: u24, d29s: u1, d30s: u1) u30 {
    const on_air: u24 = if (d30s == 1) ~d else d;
    return (@as(u30, on_air) << 6) | parityBits(d, d29s, d30s);
}

fn solveFill(d: u24, d29s: u1, d30s: u1) u24 {
    const base = d & ~@as(u24, 3);
    for (0..4) |fill| {
        const candidate = base | @as(u24, @intCast(fill));
        if (parityBits(candidate, d29s, d30s) & 3 == 0) return candidate;
    }
    unreachable;
}

pub fn encodeSubframe(source: [10]u24) [10]u30 {
    var out: [10]u30 = undefined;
    var d29s: u1 = 0;
    var d30s: u1 = 0;
    for (source, 0..) |d, i| {
        const src = if (i == 1 or i == 9) solveFill(d, d29s, d30s) else d;
        const w = word(src, d29s, d30s);
        out[i] = w;
        d30s = @truncate(w);
        d29s = @truncate(w >> 1);
    }
    return out;
}
