const set = @import("domain/messages/bds/bcnav/set");
const encode = @import("domain/messages/bds/bcnav2/encode");
pub const Set = set.Set;
pub const frame_ms = encode.frame_ms;
pub const bits_per_frame = encode.bits_per_frame;
pub const Frame = encode.Frame;
pub const buildFrame = encode.buildFrame;
