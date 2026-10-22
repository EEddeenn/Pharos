const set = @import("domain/messages/bds/bcnav3/set");
const encode = @import("domain/messages/bds/bcnav3/encode");
pub const Set = set.Set;
pub const frame_ms = encode.frame_ms;
pub const bits_per_frame = encode.bits_per_frame;
pub const Frame = encode.Frame;
pub const buildFrame = encode.buildFrame;
pub const setCycle = encode.setCycle;
