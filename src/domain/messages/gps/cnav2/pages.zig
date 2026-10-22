const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const bit_writer = @import("base/binary/bit_writer");
const dc = @import("domain/messages/gps/differential");
const text = @import("domain/messages/gps/text");
const ism = @import("domain/messages/gps/ism");
const ism_crc_from = 14;
const ism_crc_to = 218;
pub const text_length = 29;
const payload_bits = 250;
pub const Payload = frame.Bits(payload_bits);

pub fn header(prn: u8, page: u6, w: *bit_writer.BitWriter) void {
    w.writeBits(8, prn);
    w.writeBits(6, page);
}

pub fn withPrn(payload: *const Payload, prn: u8, words: []u32, w: *bit_writer.BitWriter) void {
    @memcpy(words[0..Payload.word_count], &payload.words);
    words[0] |= @as(u32, prn) << 24;
    w.skip(payload_bits);
}

pub fn encodeDc(prn: u8, epoch: dc.Epoch, packet: *const dc.Packet, w: *bit_writer.BitWriter) field.Error!void {
    header(prn, 5, w);
    try field.encode(dc.Epoch, &dc.epoch, &epoch, .{}, w);
    w.writeBits(1, dc.data_type_lnav);
    try field.encode(dc.Packet, &dc.cdc, packet, .{}, w);
    try field.encode(dc.Packet, &dc.edc, packet, .{}, w);
    w.skip(87);
}

pub fn encodeText(prn: u8, page: text.Page(text_length), w: *bit_writer.BitWriter) void {
    header(prn, 6, w);
    w.writeBits(4, page.number);
    text.write(w, &page.characters);
}

pub fn encodeConfiguration(src: *const [63]u3, w: *bit_writer.BitWriter) void {
    header(0, 7, w);
    for (src) |configuration| {
        w.writeBits(3, configuration);
    }
    w.skip(47);
}

pub fn encodeIsm(src: *const ism.Ism, w: *bit_writer.BitWriter) void {
    header(0, 8, w);
    ism.encode(src, w, 91);
    w.writeBits(32, ism.crc(w.words, ism_crc_from, ism_crc_to));
}
