const std = @import("std");
const gf256 = @import("base/binary/gf256");
pub const n = 255;
pub const k_max = 32;
pub const parity_len = n - k_max;
pub const page_octets = 53;
pub const Page = [page_octets]u8;
const Encoder = gf256.Encoder(parity_len);

pub fn encodePages(pages: []const Page, out: *[n]Page) void {
    std.debug.assert(pages.len >= 1 and pages.len <= k_max);
    for (0..page_octets) |j| {
        var info: [k_max]u8 = @splat(0);
        for (pages, 0..) |page, i| info[i] = page[j];
        var par: [parity_len]u8 = undefined;
        Encoder.parity(&info, &par);
        for (0..k_max) |i| out[i][j] = info[i];
        for (0..parity_len) |m| out[k_max + m][j] = par[m];
    }
}
