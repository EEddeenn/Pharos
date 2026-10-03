const lfsr = @import("../../codec.zig").lfsr;
const Lfsr = lfsr.Lfsr;
const weil = @import("../../codec.zig").weil;
const b1c_codes = @import("codes/b1c.zig");
const SatId = @import("../../core.zig").types.SatId;

pub const b1c_chips = b1c_codes.b1c_chips;
pub const b1c_secondary_chips = b1c_codes.b1c_secondary_chips;
pub const b1c = b1c_codes.b1c;
pub const b1cSecondary = b1c_codes.b1cSecondary;

pub const b1i_chips = 2046;
const b1i_g1_taps: u11 = 0x7C1;
const b1i_g2_taps: u11 = 0x59F;
const b1i_start: u11 = 0x2AA;

const b1i_phase = [63][3]u4{
    .{ 1, 3, 0 },   .{ 1, 4, 0 }, .{ 1, 5, 0 },  .{ 1, 6, 0 },  .{ 1, 8, 0 }, .{ 1, 9, 0 },  .{ 1, 10, 0 }, .{ 1, 11, 0 }, .{ 2, 7, 0 },
    .{ 3, 4, 0 },   .{ 3, 5, 0 }, .{ 3, 6, 0 },  .{ 3, 8, 0 },  .{ 3, 9, 0 }, .{ 3, 10, 0 }, .{ 3, 11, 0 }, .{ 4, 5, 0 },  .{ 4, 6, 0 },
    .{ 4, 8, 0 },   .{ 4, 9, 0 }, .{ 4, 10, 0 }, .{ 4, 11, 0 }, .{ 5, 6, 0 }, .{ 5, 8, 0 },  .{ 5, 9, 0 },  .{ 5, 10, 0 }, .{ 5, 11, 0 },
    .{ 6, 8, 0 },   .{ 6, 9, 0 }, .{ 6, 10, 0 }, .{ 6, 11, 0 }, .{ 8, 9, 0 }, .{ 8, 10, 0 }, .{ 8, 11, 0 }, .{ 9, 10, 0 }, .{ 9, 11, 0 },
    .{ 10, 11, 0 }, .{ 1, 2, 7 }, .{ 1, 3, 4 },  .{ 1, 3, 6 },  .{ 1, 3, 8 }, .{ 1, 3, 10 }, .{ 1, 3, 11 }, .{ 1, 4, 5 },  .{ 1, 4, 9 },
    .{ 1, 5, 6 },   .{ 1, 5, 8 }, .{ 1, 5, 10 }, .{ 1, 5, 11 }, .{ 1, 6, 9 }, .{ 1, 8, 9 },  .{ 1, 9, 10 }, .{ 1, 9, 11 }, .{ 2, 3, 7 },
    .{ 2, 5, 7 },   .{ 2, 7, 9 }, .{ 3, 4, 5 },  .{ 3, 4, 9 },  .{ 3, 5, 6 }, .{ 3, 5, 8 },  .{ 3, 5, 10 }, .{ 3, 5, 11 }, .{ 3, 6, 9 },
};

pub fn b1i(sat: SatId, out: *[b1i_chips]u8) void {
    var g1 = Lfsr(11){ .state = b1i_start, .taps = b1i_g1_taps };
    var g2 = Lfsr(11){ .state = b1i_start, .taps = b1i_g2_taps };
    var mask: u11 = 0;
    for (b1i_phase[sat.index]) |stage| {
        if (stage != 0) mask |= @as(u11, 1) << @intCast(stage - 1);
    }
    for (out) |*chip| {
        chip.* = g1.step() ^ g2.sum(mask);
        _ = g2.step();
    }
}

pub const b3i_chips = 10230;
const b3i_g1_taps: u13 = 0x100D;
const b3i_g1_restart = 8190;
const b3i_g2_taps: u13 = 0x1B71;

const b3i_g2_start = [63]u13{
    0o17765, 0o15217, 0o05075, 0o15777, 0o17423, 0o02311, 0o04577, 0o13767,
    0o04005, 0o15404, 0o00727, 0o07464, 0o12446, 0o06216, 0o11061, 0o03707,
    0o12144, 0o03340, 0o16521, 0o07550, 0o13204, 0o05064, 0o17150, 0o04314,
    0o01134, 0o11222, 0o14555, 0o04365, 0o12750, 0o17776, 0o17066, 0o11065,
    0o15251, 0o12263, 0o13513, 0o02737, 0o16324, 0o00427, 0o00473, 0o07153,
    0o02601, 0o11572, 0o03666, 0o10713, 0o04234, 0o12152, 0o06371, 0o01137,
    0o11120, 0o03241, 0o03117, 0o17062, 0o01400, 0o02001, 0o06254, 0o06115,
    0o01716, 0o05164, 0o06763, 0o12111, 0o00216, 0o04114, 0o07104,
};

pub fn b3i(sat: SatId, out: *[b3i_chips]u8) void {
    lfsr.gold(13, b3i_g1_taps, b3i_g2_taps, b3i_g2_start[sat.index], b3i_g1_restart, out);
}

pub const b2a_chips = 10230;
pub const b2b_chips = 10230;
const g1_restart = 8190;
const b2a_data_g1_taps: u13 = 0x1411;
const b2a_data_g2_taps: u13 = 0x1D14;
const b2a_pilot_g1_taps: u13 = 0x1064;
const b2a_pilot_g2_taps: u13 = 0x18D1;
const b2b_g1_taps: u13 = 0x1301;
const b2b_g2_taps: u13 = 0x192C;

const g2_state_1_60 = [60]u13{
    0x1481, 0x0581, 0x16A1, 0x1E51, 0x1551, 0x0EB1, 0x0EF1, 0x1BF1,
    0x1299, 0x0B79, 0x1585, 0x0445, 0x1545, 0x1B45, 0x0745, 0x18A5,
    0x1DE5, 0x1015, 0x0F95, 0x1AB5, 0x11B5, 0x194D, 0x08CD, 0x032D,
    0x0DAD, 0x09ED, 0x1FED, 0x091D, 0x079D, 0x10BD, 0x027D, 0x057D,
    0x1AFD, 0x19FD, 0x1143, 0x0523, 0x1DA3, 0x1113, 0x1313, 0x1AB3,
    0x11B3, 0x0973, 0x154B, 0x05CB, 0x1A6B, 0x1D5B, 0x0587, 0x1827,
    0x1A27, 0x18A7, 0x02A7, 0x1B97, 0x1D37, 0x024F, 0x052F, 0x132F,
    0x0B6F, 0x03EF, 0x1FEF, 0x15BF,
};
const b2a_data_state = g2_state_1_60 ++ [_]u13{ 0x0804, 0x15FB, 0x0978 };
const b2a_pilot_state = g2_state_1_60 ++ [_]u13{ 0x0C25, 0x03F4, 0x1558 };
const b2b_state = g2_state_1_60 ++ [_]u13{ 0x17BF, 0x143A, 0x1B9A };

pub fn b2a(sat: SatId, pilot: bool, out: *[b2a_chips]u8) void {
    if (pilot) {
        lfsr.gold(13, b2a_pilot_g1_taps, b2a_pilot_g2_taps, b2a_pilot_state[sat.index], g1_restart, out);
    } else {
        lfsr.gold(13, b2a_data_g1_taps, b2a_data_g2_taps, b2a_data_state[sat.index], g1_restart, out);
    }
}

pub fn b2b(sat: SatId, out: *[b2b_chips]u8) void {
    lfsr.gold(13, b2b_g1_taps, b2b_g2_taps, b2b_state[sat.index], g1_restart, out);
}

pub const b2a_secondary_chips = 100;
const l1021 = weil.Legendre(1021);

const Weil = struct { w: u14, p: u14 };

const b2a_secondary_codes = [63]Weil{
    .{ .w = 123, .p = 138 }, .{ .w = 55, .p = 570 },   .{ .w = 40, .p = 351 },  .{ .w = 139, .p = 77 },
    .{ .w = 31, .p = 885 },  .{ .w = 175, .p = 247 },  .{ .w = 350, .p = 413 }, .{ .w = 450, .p = 180 },
    .{ .w = 478, .p = 3 },   .{ .w = 8, .p = 26 },     .{ .w = 73, .p = 17 },   .{ .w = 97, .p = 172 },
    .{ .w = 213, .p = 30 },  .{ .w = 407, .p = 1008 }, .{ .w = 476, .p = 646 }, .{ .w = 4, .p = 158 },
    .{ .w = 15, .p = 170 },  .{ .w = 47, .p = 99 },    .{ .w = 163, .p = 53 },  .{ .w = 280, .p = 179 },
    .{ .w = 322, .p = 925 }, .{ .w = 353, .p = 114 },  .{ .w = 375, .p = 10 },  .{ .w = 510, .p = 584 },
    .{ .w = 332, .p = 60 },  .{ .w = 7, .p = 3 },      .{ .w = 13, .p = 684 },  .{ .w = 16, .p = 263 },
    .{ .w = 18, .p = 545 },  .{ .w = 25, .p = 22 },    .{ .w = 50, .p = 546 },  .{ .w = 81, .p = 190 },
    .{ .w = 118, .p = 303 }, .{ .w = 127, .p = 234 },  .{ .w = 132, .p = 38 },  .{ .w = 134, .p = 822 },
    .{ .w = 164, .p = 57 },  .{ .w = 177, .p = 668 },  .{ .w = 208, .p = 697 }, .{ .w = 249, .p = 93 },
    .{ .w = 276, .p = 18 },  .{ .w = 349, .p = 66 },   .{ .w = 439, .p = 318 }, .{ .w = 477, .p = 133 },
    .{ .w = 498, .p = 98 },  .{ .w = 88, .p = 70 },    .{ .w = 155, .p = 132 }, .{ .w = 330, .p = 26 },
    .{ .w = 3, .p = 354 },   .{ .w = 21, .p = 58 },    .{ .w = 84, .p = 41 },   .{ .w = 111, .p = 182 },
    .{ .w = 128, .p = 944 }, .{ .w = 153, .p = 205 },  .{ .w = 197, .p = 23 },  .{ .w = 199, .p = 1 },
    .{ .w = 214, .p = 792 }, .{ .w = 256, .p = 641 },  .{ .w = 265, .p = 83 },  .{ .w = 291, .p = 7 },
    .{ .w = 324, .p = 111 }, .{ .w = 326, .p = 96 },   .{ .w = 340, .p = 92 },
};

const b2a_secondary: [63][b2a_secondary_chips]u1 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [63][b2a_secondary_chips]u1 = undefined;
    for (b2a_secondary_codes, 0..) |c, k| {
        for (&t[k], 0..) |*chip, i| chip.* = l1021.weil((i + c.p - 1) % 1021, c.w);
    }
    break :blk t;
};

pub fn b2aSecondary(sat: SatId) *const [b2a_secondary_chips]u1 {
    return &b2a_secondary[sat.index];
}
