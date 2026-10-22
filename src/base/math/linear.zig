const std = @import("std");

pub fn solve(comptime N: usize, comptime R: usize, m: *[N][N]f64, rhs: *[N][R]f64) [N][R]f64 {
    for (0..N) |col| {
        var pivot = col;
        for (col + 1..N) |r| {
            if (@abs(m[r][col]) > @abs(m[pivot][col])) pivot = r;
        }
        std.mem.swap([N]f64, &m[col], &m[pivot]);
        std.mem.swap([R]f64, &rhs[col], &rhs[pivot]);
        for (col + 1..N) |r| {
            const f = m[r][col] / m[col][col];
            for (col..N) |c| m[r][c] -= f * m[col][c];
            for (0..R) |a| rhs[r][a] -= f * rhs[col][a];
        }
    }
    var x: [N][R]f64 = @splat(@splat(0));
    var row: usize = N;
    while (row > 0) {
        row -= 1;
        for (0..R) |a| {
            var sum = rhs[row][a];
            for (row + 1..N) |c| sum -= m[row][c] * x[c][a];
            x[row][a] = sum / m[row][row];
        }
    }
    return x;
}
