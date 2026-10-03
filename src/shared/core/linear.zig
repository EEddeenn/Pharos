const std = @import("std");

pub fn solve(comptime N: usize, comptime R: usize, n: usize, m: *[N][N]f64, rhs: *[N][R]f64) [N][R]f64 {
    for (0..n) |col| {
        var pivot = col;
        for (col + 1..n) |r| {
            if (@abs(m[r][col]) > @abs(m[pivot][col])) pivot = r;
        }
        std.mem.swap([N]f64, &m[col], &m[pivot]);
        std.mem.swap([R]f64, &rhs[col], &rhs[pivot]);
        for (col + 1..n) |r| {
            const f = m[r][col] / m[col][col];
            for (col..n) |c| m[r][c] -= f * m[col][c];
            for (0..R) |a| rhs[r][a] -= f * rhs[col][a];
        }
    }
    var x: [N][R]f64 = @splat(@splat(0));
    var row = n;
    while (row > 0) {
        row -= 1;
        for (0..R) |a| {
            var sum = rhs[row][a];
            for (row + 1..n) |c| sum -= m[row][c] * x[c][a];
            x[row][a] = sum / m[row][row];
        }
    }
    return x;
}
