const types = @import("../../../core.zig").types;
const time = @import("../../../core.zig").time;

pub const frame_ms = 2000;
pub const offset_ms = 1000;
const pages_per_subframe = 15;
const subframe_s = 30;
const cycle_s = 720;
const e1_half_cycle_s = 360;

const allocation_e1 = [pages_per_subframe]u6{ 2, 4, 6, 7, 8, 17, 19, 16, 0, 22, 1, 3, 5, 0, 16 };
const allocation_e5b = [pages_per_subframe]u6{ 1, 3, 5, 7, 8, 0, 0, 0, 0, 0, 2, 4, 6, 0, 0 };
pub const Carrier = enum {
    e1,
    e5b,

    pub fn of(signal: types.Signal) Carrier {
        return switch (signal) {
            .e1 => .e1,
            .e5b => .e5b,
            else => unreachable,
        };
    }

    pub fn frameMs(_: Carrier) u32 {
        return frame_ms;
    }
};
const ssp = [3]u8{ 0x04, 0x2B, 0x2F };

const Slot = struct {
    word: u6,
    tow: u20,
    wn: u12,
    group: u4,
    ssp: ?u8,
};

pub fn slot(index: i64, carrier: Carrier) Slot {
    const e1 = carrier == .e1;
    const start_ms = index * frame_ms - @as(i64, if (e1) offset_ms else 0);
    const tow = @mod(@divFloor(start_ms, 1000), time.s_per_week);
    const wn = @mod(time.weekOfIndex(start_ms, time.ms_per_week, .gal), time.week_modulus_12);
    const subframe = @divFloor(@mod(tow + @as(i64, if (e1) e1_half_cycle_s else 0), cycle_s), subframe_s);
    const pg = @divFloor(@mod(tow, subframe_s), 2);
    var word = (if (e1) allocation_e1 else allocation_e5b)[@intCast(pg)];
    if (@mod(subframe, 2) == 1) word = switch (word) {
        7 => 9,
        8 => 10,
        17 => 18,
        19 => 20,
        else => word,
    };
    return .{
        .word = word,
        .tow = @intCast(tow),
        .wn = @intCast(wn),
        .group = @intCast(@divFloor(subframe, 2)),
        .ssp = if (e1) ssp[@intCast(@mod(pg, 3))] else null,
    };
}
