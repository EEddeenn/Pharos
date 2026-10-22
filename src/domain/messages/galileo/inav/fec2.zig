const gf256 = @import("base/binary/gf256");
pub const info_len = 58;
pub const parity_len = 60;
const Encoder = gf256.Encoder(parity_len);

pub fn parity(info: *const [info_len]u8) [parity_len]u8 {
    var highest_first: [info_len]u8 = undefined;
    for (0..info_len) |k| highest_first[k] = info[info_len - 1 - k];
    var rem: [parity_len]u8 = undefined;
    Encoder.parity(&highest_first, &rem);
    var out: [parity_len]u8 = undefined;
    for (0..parity_len) |k| out[k] = rem[parity_len - 1 - k];
    return out;
}
