const frame = @import("../../codec.zig").frame;
const conv = @import("../../codec.zig").conv;
const content = @import("cnav/content.zig");
const schedule = @import("cnav/schedule.zig");

pub const Carrier = schedule.Carrier;
pub const frame_ms = schedule.frame_ms;
const message_bits = content.message_bits;
pub const bits_per_frame = 2 * message_bits;
pub const Frame = frame.Bits(bits_per_frame);
const Message = content.Message;
pub const Set = content.Set;

fn tailState(m: *const Message) u6 {
    var state: u6 = 0;
    for (0..6) |i| state |= @as(u6, m.get(message_bits - 1 - i)) << @intCast(i);
    return state;
}

fn encodeSymbols(m: *const Message, state: u6) Frame {
    var encoder = conv.Encoder{ .state = state };
    var out: Frame = .{};
    for (0..message_bits) |i| {
        const s = encoder.push(m.get(i));
        out.set(2 * i, s.g1);
        out.set(2 * i + 1, s.g2);
    }
    return out;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    return buildFrameAfter(set, set, prn, index, carrier);
}

pub fn buildFrameAfter(set: *const Set, previous_set: *const Set, prn: u8, index: i64, carrier: Carrier) ?Frame {
    const m = set.message(prn, index, carrier) orelse return null;
    const previous = previous_set.message(prn, index - 1, carrier) orelse return null;
    return encodeSymbols(&m, tailState(&previous));
}
