const frame = @import("base/binary/bits");
const coding = @import("domain/messages/galileo/coding");
pub const symbols_per_page = 500;
const content_bits = 214;
pub const Page = frame.Bits(symbols_per_page);
pub const Content = frame.Bits(content_bits);
const sync: u12 = 0b1011_0111_0000;

pub fn encode(content: *const Content) Page {
    return coding.page(Page, sync, content_bits, content);
}
