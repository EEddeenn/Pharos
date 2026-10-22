const field = @import("base/binary/field");
const time = @import("domain/time/gps");
const epoch = @import("domain/navigation/almanac_epoch");
pub const Reference = struct {
    wna: u13,
    toa: u8,

    pub fn fromTime(t: time.GpsTime, scale: time.WeekScale) Reference {
        const value = t.inScale(scale);
        return .{ .wna = @intCast(@mod(value.period, time.week_modulus_13)), .toa = @intCast(value.ms / epoch.toa_step_ms) };
    }
};

pub const rows = [_]field.Field(Reference){
    .{ .name = "wna", .width = 13, .src = .{ .field = "wna" } },
    .{ .name = "toa", .width = 8, .src = .{ .field = "toa" } },
};
