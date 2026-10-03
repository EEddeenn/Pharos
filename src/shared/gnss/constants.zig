const std = @import("std");
const types = @import("../core.zig").types;
const SystemConstants = @import("../core.zig").constants.SystemConstants;
const gps = @import("gps/constants.zig");
const bds = @import("bds/constants.zig");
const galileo = @import("galileo/constants.zig");
const glonass = @import("glonass/constants.zig");

const table = std.EnumArray(types.System, SystemConstants).init(.{
    .gps = gps.orbit,
    .bds = bds.orbit,
    .gal = galileo.orbit,
    .glo = glonass.orbit,
});

pub fn get(system: types.System) *const SystemConstants {
    return table.getPtrConst(system);
}
