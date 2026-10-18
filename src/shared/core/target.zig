const builtin = @import("builtin");

pub const has_file_system = builtin.target.os.tag != .freestanding;
pub const has_wall_clock = builtin.target.os.tag != .freestanding;
