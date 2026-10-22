const has_content = @import("domain/messages/galileo/has/content");
const frame = @import("base/binary/bits");
const coding = @import("domain/messages/galileo/coding");
const Supplier = @import("domain/messages/supplier").Supplier;
pub const frame_ms = 1000;
pub const bits_per_frame = 1000;
const content_bits = 462;
pub const Frame = frame.Bits(bits_per_frame);
pub const Content = frame.Bits(content_bits);
const sync: u16 = 0xB770;
pub const reserved_bits = 14;
const header_bits = 24;
const dummy_header: u24 = 0xAF3BC3;

const dummy_page: Frame = blk: {
    @setEvalBranchQuota(400_000);
    break :blk encode(&dummyContent());
};

pub const PageSource = Supplier(has_content.PageRequest, has_content.PagePayload);
pub const Set = struct {
    pages: ?PageSource = null,

    pub const Inputs = struct { pages: ?PageSource = null };

    pub fn init(input: Inputs) Set {
        return .{ .pages = input.pages };
    }
};

pub fn encode(content: *const Content) Frame {
    return coding.page(Frame, sync, content_bits, content);
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (set.pages) |source| if (source.read(.{ .prn = prn, .index = index })) |page| return encodePage(page);
    return dummy_page;
}

fn dummyContent() Content {
    var c: Content = .{};
    var w = c.writer();
    w.writeBits(reserved_bits, 0);
    w.writeBits(header_bits, dummy_header);
    return c;
}

fn encodePage(page: has_content.PagePayload) Frame {
    const header = page.header;
    var content: Content = .{};
    var writer = content.writer();
    writer.writeBits(reserved_bits, 0);
    writer.writeBits(2, @backingInt(header.status));
    writer.writeBits(2, 0);
    writer.writeBits(2, header.message_type);
    writer.writeBits(5, header.message_id);
    writer.writeBits(5, @as(u5, @intCast(header.size - 1)));
    writer.writeBits(8, header.page_id);
    for (page.body) |byte| writer.writeBits(8, byte);
    return encode(&content);
}
