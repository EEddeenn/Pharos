const std = @import("std");
const gnss = @import("../gnss.zig");

pub const Messages = struct {
    gps: []const gnss.gps.messages.Publication = &.{},
    inav: []const gnss.galileo.inav.ism.Publication = &.{},
    d2: []const gnss.bds.d1d2.augmentation.Publication = &.{},

    pub fn ordered(self: *const Messages) bool {
        inline for (std.meta.fields(Messages)) |f| {
            if (!gnss.publication.ordered(@field(self, f.name))) return false;
        }
        return true;
    }
};
