const std = @import("std");
const gf = @import("base/binary/gf");
const frame = @import("base/binary/bits");
const gf64_poly = 0x43;
const Gf64 = gf.Gf(6, gf64_poly);

pub fn Gf2Systematic(comptime n_parity: usize, comptime n_words: usize) type {
    return struct {
        rows: *const [n_parity][n_words]u32,

        const Self = @This();

        pub fn init(comptime blob: []const u8) Self {
            comptime {
                if (blob.len != n_parity * n_words * 4) @compileError("generator blob size does not match the code dimensions");
            }
            const rows = comptime blk: {
                @setEvalBranchQuota(4 * n_parity * n_words + 1000);
                var r: [n_parity][n_words]u32 = undefined;
                for (0..n_parity) |i| for (0..n_words) |j| {
                    r[i][j] = std.mem.readInt(u32, blob[(i * n_words + j) * 4 ..][0..4], .big);
                };
                break :blk r;
            };
            return .{ .rows = &rows };
        }

        pub fn parity(self: Self, words: *const [n_words]u32, out: *[n_parity]u1) void {
            for (self.rows, out) |row, *bit| {
                var acc: u32 = 0;
                for (row, words) |m, w| acc ^= m & w;
                bit.* = @truncate(@popCount(acc));
            }
        }
    };
}

pub fn Gf64Systematic(comptime n: usize) type {
    return struct {
        matrix: *const [n][n]u6,

        const Self = @This();

        pub fn init(comptime blob: []const u8) Self {
            comptime {
                if (blob.len != n * n) @compileError("generator blob size does not match the code dimensions");
            }
            const matrix = comptime blk: {
                @setEvalBranchQuota(4 * n * n + 1000);
                var m: [n][n]u6 = undefined;
                for (0..n) |i| for (0..n) |j| {
                    if (blob[i * n + j] > 63) @compileError("generator symbol out of GF(2^6)");
                    m[i][j] = @intCast(blob[i * n + j]);
                };
                break :blk m;
            };
            return .{ .matrix = &matrix };
        }

        pub fn codeword(self: Self, message: *const frame.Bits(6 * n), out: *[12 * n]u1) void {
            var symbols: [2 * n]u6 = undefined;
            symbolsOf(6 * n, message, symbols[0..n]);
            self.parity(symbols[0..n], symbols[n..]);
            bitsOf(&symbols, out);
        }

        fn parity(self: Self, message: *const [n]u6, out: *[n]u6) void {
            for (self.matrix, out) |row, *p| {
                var acc: u6 = 0;
                for (row, message) |m, s| acc ^= Gf64.mul(m, s);
                p.* = acc;
            }
        }
    };
}

fn symbolsOf(comptime n: usize, bits: *const frame.Bits(n), out: *[n / 6]u6) void {
    for (out, 0..) |*s, k| {
        var v: u6 = 0;
        for (0..6) |b| v = (v << 1) | bits.get(6 * k + b);
        s.* = v;
    }
}

fn bitsOf(symbols: []const u6, out: []u1) void {
    for (symbols, 0..) |s, k| for (0..6) |b| {
        out[6 * k + b] = @truncate(s >> @intCast(5 - b));
    };
}
