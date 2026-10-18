const std = @import("std");
const frame = @import("../../../codec.zig").frame;
const cnav = @import("../cnav.zig");
const rs = @import("rs.zig");

const page_bits = 424;
pub const max_pages = 32;
const max_message_bits = page_bits * max_pages;
const Page = rs.Page;
pub const MessageBits = frame.Bits(max_message_bits);

pub const Status = enum(u2) { test_mode = 0, operational = 1, reserved = 2, do_not_use = 3 };

pub const Header = struct {
    status: Status,
    message_type: u2 = 1,
    message_id: u5,
    size: u6,
    page_id: u8,
};

fn pageCount(bit_count: usize) usize {
    return @max(1, (bit_count + page_bits - 1) / page_bits);
}

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

pub fn cnavPage(header: Header, body: *const Page) cnav.Frame {
    var content: cnav.Content = .{};
    var w = content.writer();
    w.writeBits(cnav.reserved_bits, 0);
    w.writeBits(2, @backingInt(header.status));
    w.writeBits(2, 0);
    w.writeBits(2, header.message_type);
    w.writeBits(5, header.message_id);
    w.writeBits(5, @as(u5, @intCast(header.size - 1)));
    w.writeBits(8, header.page_id);
    for (body) |byte| w.writeBits(8, byte);
    return cnav.encode(&content);
}
