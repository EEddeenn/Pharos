const std = @import("std");
const frame = @import("base/binary/bits");
const rs = @import("domain/messages/galileo/has/reed_solomon");
const Page = rs.Page;
const page_bits = 424;
pub const max_pages = 32;
const max_message_bits = page_bits * max_pages;
pub const MessageBits = frame.Bits(max_message_bits);

pub fn split(bits: *const MessageBits, bit_count: usize, out: *[max_pages]Page) usize {
    std.debug.assert(bit_count <= max_message_bits);
    const k = pageCount(bit_count);
    for (0..k) |p| {
        for (0..rs.page_octets) |j| {
            var byte: u8 = 0;
            for (0..8) |b| {
                const i = p * page_bits + 8 * j + b;
                const bit: u1 = if (i < bit_count) bits.get(i) else @intCast((i - bit_count) & 1);
                byte = (byte << 1) | bit;
            }
            out[p][j] = byte;
        }
    }
    return k;
}

fn pageCount(bit_count: usize) usize {
    return @max(1, (bit_count + page_bits - 1) / page_bits);
}
