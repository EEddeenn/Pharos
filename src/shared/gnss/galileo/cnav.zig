const frame = @import("../../codec.zig").frame;
const coding = @import("coding.zig");

pub const frame_ms = 1000;
pub const bits_per_frame = 1000;
const content_bits = 462;
pub const Frame = frame.Bits(bits_per_frame);
pub const Content = frame.Bits(content_bits);

const sync: u16 = 0xB770;
pub const reserved_bits = 14;
const header_bits = 24;
const dummy_header: u24 = 0xAF3BC3;

fn dummyContent() Content {
    var c: Content = .{};
    var w = c.writer();
    w.writeBits(reserved_bits, 0);
    w.writeBits(header_bits, dummy_header);
    return c;
}

pub fn encode(content: *const Content) Frame {
    return coding.page(Frame, sync, content_bits, content);
}

const dummy_page: Frame = blk: {
    @setEvalBranchQuota(400_000);
    break :blk encode(&dummyContent());
};

pub const PageSource = frame.Source(bits_per_frame);

pub const Set = struct {
    pages: ?PageSource = null,

    pub const Inputs = struct { pages: ?PageSource = null };

    pub fn build(set: *Set, in: Inputs) void {
        set.* = .{ .pages = in.pages };
    }

    pub fn hasRecord(_: *const Set, _: u8) bool {
        return true;
    }
};

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (set.pages) |source| if (source.frame(prn, index)) |f| return f;
    return dummy_page;
}
