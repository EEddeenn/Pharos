const std = @import("std");
const field = @import("../../../codec.zig").field;
const almanac_fields = @import("../almanac_fields.zig");
const time_parameters = @import("../time_parameters.zig");

const Group = almanac_fields.Group;
const G = field.Field(Group);
const tail: []const [:0]const u8 = &.{ "af0", "af1", "health" };

pub const word7 = [_]G{
    .{ .name = "type", .width = 6, .src = .{ .constant = 7 } },
} ++
    almanac_fields.almanac_head ++
    almanac_fields.svRows(0, almanac_fields.head) ++
    [_]G{
        .{ .name = "spare_7", .width = 6, .src = .reserved },
    };

pub const word8 = [_]G{
    .{ .name = "type", .width = 6, .src = .{ .constant = 8 } },
    almanac_fields.almanac_head[0],
} ++
    almanac_fields.svRows(0, tail) ++
    almanac_fields.svRows(1, almanac_fields.head[0..7]) ++
    [_]G{
        .{ .name = "spare_8", .width = 1, .src = .reserved },
    };

pub const word9 = [_]G{
    .{ .name = "type", .width = 6, .src = .{ .constant = 9 } },
} ++
    almanac_fields.almanac_head ++
    almanac_fields.svRows(1, almanac_fields.head[7..8]) ++
    almanac_fields.svRows(1, tail) ++
    almanac_fields.svRows(2, almanac_fields.head[0..5]);

pub const word10 = [_]G{
    .{ .name = "type", .width = 6, .src = .{ .constant = 10 } },
    almanac_fields.almanac_head[0],
} ++
    almanac_fields.svRows(2, almanac_fields.head[5..8]) ++
    almanac_fields.svRows(2, tail);

pub const word10_ggto = [_]field.Field(time_parameters.Ggto){ time_parameters.a0g, time_parameters.a1g, time_parameters.t0g_h, time_parameters.wn0g };

comptime {
    for (.{ word7, word8, word9 }) |layout| std.debug.assert(field.totalWidth(Group, &layout) == 128);
    std.debug.assert(field.totalWidth(Group, &word10) + field.totalWidth(time_parameters.Ggto, &word10_ggto) == 128);
}
