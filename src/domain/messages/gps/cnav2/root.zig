const set = @import("domain/messages/gps/cnav2/set");
const encode = @import("domain/messages/gps/cnav2/encode");
pub const Set = set.Set;
pub const frame_ms = encode.frame_ms;
pub const bits_per_frame = encode.bits_per_frame;
pub const Frame = encode.Frame;
pub const buildFrame = encode.buildFrame;
