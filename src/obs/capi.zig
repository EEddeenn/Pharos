pub const common = @import("capi/common.zig");
pub const source = @import("capi/source.zig");
pub const output = @import("capi/output.zig");
pub const truth = @import("capi/truth.zig");

comptime {
    _ = common;
    _ = source;
    _ = output;
    _ = truth;
}
