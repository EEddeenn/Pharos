const time = @import("../../../core.zig").time;
const grid = @import("grid.zig");

pub const d1_frame_ms = 6000;
pub const d2_pages_per_superframe = 120;
pub const d2_frame_ms = 600;
pub const cycle_ms = 30_000;

const D1Slot = struct { subframe: u3, page: u5, cycle: u2, sow: u20 };

pub fn d1Slot(index: i64) D1Slot {
    const sow = @mod(index * 6, time.s_per_week);
    const frame_no = @divFloor(sow, 30);
    return .{
        .subframe = @intCast(@mod(@divFloor(sow, 6), 5) + 1),
        .page = @intCast(@mod(frame_no, 24)),
        .cycle = @intCast(@divFloor(@mod(frame_no, 72), 24)),
        .sow = @intCast(sow),
    };
}

const D2Slot = struct { subframe: u3, page: u7, cycle: u2, sow: u20 };

pub fn d2Slot(index: i64) D2Slot {
    const frame_no = @divFloor(index, 5);
    const subframe: u3 = @intCast(@mod(index, 5) + 1);
    const page: i64 = switch (subframe) {
        1 => @mod(frame_no, 10),
        2, 3, 4 => @mod(frame_no, 6),
        else => @mod(frame_no, d2_pages_per_superframe),
    };
    const cycle: u2 = @intCast(@mod(@divFloor(frame_no, d2_pages_per_superframe), 3));
    const sow: u20 = @intCast(@mod(frame_no * 3, time.s_per_week));

    return .{ .subframe = subframe, .page = @intCast(page), .cycle = cycle, .sow = sow };
}

pub const Ephemeris = enum { sf1, sf2, sf3, d2_page1, d2_page2, d2_page3, d2_page4, d2_page5, d2_page6, d2_page7, d2_page8, d2_page9, d2_page10 };
pub const d1_subframes = [_]Ephemeris{ .sf1, .sf2, .sf3 };
pub const d2_pages = [_]Ephemeris{ .d2_page1, .d2_page2, .d2_page3, .d2_page4, .d2_page5, .d2_page6, .d2_page7, .d2_page8, .d2_page9, .d2_page10 };

pub const Navigation = union(enum) {
    ephemeris: Ephemeris,
    almanac: struct { slot: u6, pnum: u7, am_id: u2 },
    health7: u7,
    health8: u7,
    health24: struct { pnum: u7, am_id: u2 },
    offsets: u7,
    utc: u7,
    reserved: struct { pnum: u7, am_id: u2 },
};

pub const Augmentation = union(enum) {
    integrity: struct { subframe: u3, page: u4 },
    grid: u7,
};

pub const Content = union(enum) { navigation: Navigation, augmentation: Augmentation };

fn expandedAlmanac(j: u7, pnum: u7, cycle: u2) Navigation {
    const am_id: u2 = cycle + 1;
    if (cycle < 2 or j < 7) return .{ .almanac = .{ .slot = @intCast(30 + 13 * @as(u7, cycle) + j), .pnum = pnum, .am_id = am_id } };
    return .{ .reserved = .{ .pnum = pnum, .am_id = am_id } };
}

pub fn d1Content(s: D1Slot) Navigation {
    return switch (s.subframe) {
        1 => .{ .ephemeris = .sf1 },
        2 => .{ .ephemeris = .sf2 },
        3 => .{ .ephemeris = .sf3 },
        4 => .{ .almanac = .{ .slot = s.page, .pnum = @as(u7, s.page) + 1, .am_id = 3 } },
        else => blk: {
            const p: u7 = s.page;
            if (p < 6) break :blk .{ .almanac = .{ .slot = @intCast(24 + p), .pnum = p + 1, .am_id = 3 } };
            break :blk switch (p) {
                6 => .{ .health7 = 7 },
                7 => .{ .health8 = 8 },
                8 => .{ .offsets = 9 },
                9 => .{ .utc = 10 },
                23 => .{ .health24 = .{ .pnum = 24, .am_id = s.cycle + 1 } },
                else => expandedAlmanac(p - 10, p + 1, s.cycle),
            };
        },
    };
}

pub fn d2Content(s: D2Slot) Content {
    return switch (s.subframe) {
        1 => .{ .navigation = .{ .ephemeris = d2_pages[s.page] } },
        2, 3, 4 => .{ .augmentation = .{ .integrity = .{ .subframe = s.subframe, .page = @intCast(s.page + 1) } } },
        else => blk: {
            const p: u7 = s.page + 1;
            if (grid.isPage(p)) break :blk .{ .augmentation = .{ .grid = p } };
            break :blk .{ .navigation = d2Subframe5(p, s.cycle) };
        },
    };
}

fn d2Subframe5(p: u7, cycle: u2) Navigation {
    if (p >= 37 and p <= 60) return .{ .almanac = .{ .slot = @intCast(p - 37), .pnum = p, .am_id = 3 } };
    if (p >= 95 and p <= 100) return .{ .almanac = .{ .slot = @intCast(p - 71), .pnum = p, .am_id = 3 } };
    if (p >= 103 and p <= 115) return expandedAlmanac(p - 103, p, cycle);
    return switch (p) {
        35 => .{ .health7 = 35 },
        36 => .{ .health8 = 36 },
        101 => .{ .offsets = 101 },
        102 => .{ .utc = 102 },
        116 => .{ .health24 = .{ .pnum = 116, .am_id = cycle + 1 } },
        else => .{ .reserved = .{ .pnum = p, .am_id = 0 } },
    };
}
