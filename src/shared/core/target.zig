const builtin = @import("builtin");

pub const has_file_system = builtin.os.tag != .freestanding;
pub const has_wall_clock = builtin.os.tag != .freestanding;
