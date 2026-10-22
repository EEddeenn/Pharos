const word = @import("domain/messages/bds/d1d2/word");
const BitWriter = @import("base/binary/bit_writer").BitWriter;
pub const basic_packets = 18;
pub const max_packets = 24;
pub const basic_ids = 30;
const Packet = struct { rurai: u4, udrei: u4, delta_t: i13 };
pub const delta_t_unavailable: i13 = -4096;
const unused: Packet = .{ .rurai = 15, .udrei = 15, .delta_t = delta_t_unavailable };
pub const Block = struct {
    sat_h2: u2,
    bdid: [63]bool = @splat(false),
    packets: [max_packets]Packet = @splat(unused),
    expanded: bool = false,

    pub const none: Block = .{ .sat_h2 = 0b11 };

    pub fn narrowed(self: *const Block) Block {
        var out: Block = .{ .sat_h2 = self.sat_h2 };
        var k: usize = 0;
        for (self.bdid[0..basic_ids], 0..) |present, i| if (present and k < basic_packets) {
            out.bdid[i] = true;
            out.packets[k] = self.packets[k];
            k += 1;
        };
        return out;
    }
};

pub fn encode(src: *const Block, subframe: u3, page: u4, sow_lsb: u12) word.Info {
    var out: word.Info = .{};
    var w = out.writer();
    w.writeBits(12, sow_lsb);
    w.skip(1);
    const first: usize = 3 * (@as(usize, page) - 1);
    switch (subframe) {
        2 => {
            w.writeBits(4, page);
            w.writeBits(2, src.sat_h2);
            for (src.bdid[0..basic_ids]) |present| w.writeBits(1, present);
            w.skip(60);
            for (src.packets[0..basic_packets]) |p| w.writeBits(4, p.udrei);
            writePacket(&w, src.packets[first]);
        },
        3 => {
            writePacket(&w, src.packets[first + 1]);
            writePacket(&w, src.packets[first + 2]);
            w.skip(151);
        },
        4 => {
            w.skip(93);
            const bdepid: u2 = if (src.expanded) 3 else 0;
            w.writeBits(2, bdepid);
            if (src.expanded) {
                for (src.bdid[basic_ids..63]) |present| w.writeBits(1, present);
                for (src.packets[basic_packets..max_packets]) |p| w.writeBits(4, p.udrei);
                writePacket(&w, src.packets[basic_packets - 1 + @as(usize, page)]);
                w.skip(16);
            } else w.skip(90);
        },
        else => unreachable,
    }
    return out;
}

fn writePacket(w: *BitWriter, p: Packet) void {
    w.writeBits(4, p.rurai);
    w.writeBits(13, p.delta_t);
}
