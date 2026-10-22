const lfsr = @import("base/binary/lfsr");
const weil = @import("base/binary/weil");
const SatId = @import("domain/gnss_types").SatId;
const Lfsr = lfsr.Lfsr;
const Modular = lfsr.Modular;

const l1ca_g2_stages = [32][2]u4{
    .{ 2, 6 },  .{ 3, 7 }, .{ 4, 8 }, .{ 5, 9 },  .{ 1, 9 }, .{ 2, 10 }, .{ 1, 8 }, .{ 2, 9 },
    .{ 3, 10 }, .{ 2, 3 }, .{ 3, 4 }, .{ 5, 6 },  .{ 6, 7 }, .{ 7, 8 },  .{ 8, 9 }, .{ 9, 10 },
    .{ 1, 4 },  .{ 2, 5 }, .{ 3, 6 }, .{ 4, 7 },  .{ 5, 8 }, .{ 6, 9 },  .{ 1, 3 }, .{ 4, 6 },
    .{ 5, 7 },  .{ 6, 8 }, .{ 7, 9 }, .{ 8, 10 }, .{ 1, 6 }, .{ 2, 7 },  .{ 3, 8 }, .{ 4, 9 },
};

pub const l1ca_chips = 1023;

pub const l5_chips = 10230;
const xa_taps: u13 = 0x1B00;
const xa_restart = 8190;
const xb_taps: u13 = 0x18ED;

const xb_state_i5 = [32]u13{
    0o02352, 0o12603, 0o01002, 0o06215, 0o16567, 0o05746, 0o17445, 0o02275,
    0o15237, 0o07576, 0o05620, 0o11747, 0o03470, 0o16202, 0o05526, 0o11170,
    0o17062, 0o07417, 0o17423, 0o13326, 0o01004, 0o17367, 0o07741, 0o02643,
    0o13313, 0o06465, 0o07552, 0o06536, 0o10372, 0o16641, 0o07450, 0o11640,
};
const xb_state_q5 = [32]u13{
    0o03151, 0o06742, 0o14217, 0o05334, 0o04674, 0o11252, 0o10077, 0o01326,
    0o14135, 0o06044, 0o12010, 0o12152, 0o12262, 0o17605, 0o17075, 0o17513,
    0o01147, 0o02355, 0o15514, 0o10703, 0o00466, 0o07064, 0o13721, 0o14766,
    0o15442, 0o03652, 0o05741, 0o04137, 0o02212, 0o11701, 0o12372, 0o05211,
};

pub const nh20 = [20]u1{ 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 1, 1, 1, 0 };

pub const l2cm_chips = 10230;
pub const l2cl_chips = 767_250;
const l2c_taps: u27 = 0x494953C;

const l2cm_state = [32]u27{
    0o742417664, 0o756014035, 0o002747144, 0o066265724, 0o601403471, 0o703232733, 0o124510070, 0o617316361,
    0o047541621, 0o733031046, 0o713512145, 0o024437606, 0o021264003, 0o230655351, 0o001314400, 0o222021506,
    0o540264026, 0o205521705, 0o064022144, 0o120161274, 0o044023533, 0o724744327, 0o045743577, 0o741201660,
    0o700274134, 0o010247261, 0o713433445, 0o737324162, 0o311627434, 0o710452007, 0o722462133, 0o050172213,
};
const l2cl_state = [32]u27{
    0o624145772, 0o506610362, 0o220360016, 0o710406104, 0o001143345, 0o053023326, 0o652521276, 0o206124777,
    0o015563374, 0o561522076, 0o023163525, 0o117776450, 0o606516355, 0o003037343, 0o046515565, 0o671511621,
    0o605402220, 0o002576207, 0o525163451, 0o266527765, 0o006760703, 0o501474556, 0o743747443, 0o615534726,
    0o763621420, 0o720727474, 0o700521043, 0o222567263, 0o132765304, 0o746332245, 0o102300466, 0o255231716,
};

pub const l1c_chips = 10230;
pub const l1c_overlay_chips = 1800;
const legendre_10223 = weil.Legendre(10223);
const l1c_inserted = [7]u1{ 0, 1, 1, 0, 1, 0, 0 };

const Weil = struct { w: u14, p: u14 };

const l1c_data = [32]Weil{
    .{ .w = 5097, .p = 181 },  .{ .w = 5110, .p = 359 },  .{ .w = 5079, .p = 72 },   .{ .w = 4403, .p = 1110 },
    .{ .w = 4121, .p = 1480 }, .{ .w = 5043, .p = 5034 }, .{ .w = 5042, .p = 4622 }, .{ .w = 5104, .p = 1 },
    .{ .w = 4940, .p = 4547 }, .{ .w = 5035, .p = 826 },  .{ .w = 4372, .p = 6284 }, .{ .w = 5064, .p = 4195 },
    .{ .w = 5084, .p = 368 },  .{ .w = 5048, .p = 1 },    .{ .w = 4950, .p = 4796 }, .{ .w = 5019, .p = 523 },
    .{ .w = 5076, .p = 151 },  .{ .w = 3736, .p = 713 },  .{ .w = 4993, .p = 9850 }, .{ .w = 5060, .p = 5734 },
    .{ .w = 5061, .p = 34 },   .{ .w = 5096, .p = 6142 }, .{ .w = 4983, .p = 190 },  .{ .w = 4783, .p = 644 },
    .{ .w = 4991, .p = 467 },  .{ .w = 4815, .p = 5384 }, .{ .w = 4443, .p = 801 },  .{ .w = 4769, .p = 594 },
    .{ .w = 4879, .p = 4450 }, .{ .w = 4894, .p = 9437 }, .{ .w = 4985, .p = 4307 }, .{ .w = 5056, .p = 5906 },
};
const l1c_pilot = [32]Weil{
    .{ .w = 5111, .p = 412 },  .{ .w = 5109, .p = 161 },  .{ .w = 5108, .p = 1 },    .{ .w = 5106, .p = 303 },
    .{ .w = 5103, .p = 207 },  .{ .w = 5101, .p = 4971 }, .{ .w = 5100, .p = 4496 }, .{ .w = 5098, .p = 5 },
    .{ .w = 5095, .p = 4557 }, .{ .w = 5094, .p = 485 },  .{ .w = 5093, .p = 253 },  .{ .w = 5091, .p = 4676 },
    .{ .w = 5090, .p = 1 },    .{ .w = 5081, .p = 66 },   .{ .w = 5080, .p = 4485 }, .{ .w = 5069, .p = 282 },
    .{ .w = 5068, .p = 193 },  .{ .w = 5054, .p = 5211 }, .{ .w = 5044, .p = 729 },  .{ .w = 5027, .p = 4848 },
    .{ .w = 5026, .p = 982 },  .{ .w = 5014, .p = 5955 }, .{ .w = 5004, .p = 9805 }, .{ .w = 4980, .p = 670 },
    .{ .w = 4915, .p = 464 },  .{ .w = 4909, .p = 29 },   .{ .w = 4893, .p = 429 },  .{ .w = 4885, .p = 394 },
    .{ .w = 4832, .p = 616 },  .{ .w = 4824, .p = 9457 }, .{ .w = 4591, .p = 4429 }, .{ .w = 3706, .p = 4771 },
};

const Overlay = struct { poly: u12, init: u11 };

const l1c_overlays = [32]Overlay{
    .{ .poly = 0o5111, .init = 0o3266 }, .{ .poly = 0o5421, .init = 0o2040 }, .{ .poly = 0o5501, .init = 0o1527 }, .{ .poly = 0o5403, .init = 0o3307 },
    .{ .poly = 0o6417, .init = 0o3756 }, .{ .poly = 0o6141, .init = 0o3026 }, .{ .poly = 0o6351, .init = 0o0562 }, .{ .poly = 0o6501, .init = 0o0420 },
    .{ .poly = 0o6205, .init = 0o3415 }, .{ .poly = 0o6235, .init = 0o0337 }, .{ .poly = 0o7751, .init = 0o0265 }, .{ .poly = 0o6623, .init = 0o1230 },
    .{ .poly = 0o6733, .init = 0o2204 }, .{ .poly = 0o7627, .init = 0o1440 }, .{ .poly = 0o5667, .init = 0o2412 }, .{ .poly = 0o5051, .init = 0o3516 },
    .{ .poly = 0o7665, .init = 0o2761 }, .{ .poly = 0o6325, .init = 0o3750 }, .{ .poly = 0o4365, .init = 0o2701 }, .{ .poly = 0o4745, .init = 0o1206 },
    .{ .poly = 0o7633, .init = 0o1544 }, .{ .poly = 0o6747, .init = 0o1774 }, .{ .poly = 0o4475, .init = 0o0546 }, .{ .poly = 0o4225, .init = 0o2213 },
    .{ .poly = 0o7063, .init = 0o3707 }, .{ .poly = 0o4423, .init = 0o2051 }, .{ .poly = 0o6651, .init = 0o3650 }, .{ .poly = 0o4161, .init = 0o1777 },
    .{ .poly = 0o7237, .init = 0o3203 }, .{ .poly = 0o4473, .init = 0o1762 }, .{ .poly = 0o5477, .init = 0o2100 }, .{ .poly = 0o6163, .init = 0o0571 },
};

const l1c_overlay: [32][l1c_overlay_chips]u1 = blk: {
    @setEvalBranchQuota(400_000);
    var t: [32][l1c_overlay_chips]u1 = undefined;
    for (l1c_overlays, 0..) |o, k| {
        var r = Lfsr(11){ .state = o.init, .taps = @truncate(o.poly >> 1) };
        for (&t[k]) |*chip| chip.* = r.step();
    }
    break :blk t;
};

pub fn l1ca(sat: SatId, out: *[l1ca_chips]u8) void {
    var g1 = Lfsr(10){ .state = 0x3FF, .taps = (1 << 2) | (1 << 9) };
    var g2 = Lfsr(10){ .state = 0x3FF, .taps = (1 << 1) | (1 << 2) | (1 << 5) | (1 << 7) | (1 << 8) | (1 << 9) };
    const sel = l1ca_g2_stages[sat.index];
    const sel_mask: u10 = (@as(u10, 1) << (sel[0] - 1)) | (@as(u10, 1) << (sel[1] - 1));
    for (out) |*chip| {
        chip.* = g1.step() ^ g2.sum(sel_mask);
        _ = g2.step();
    }
}

pub fn l5(sat: SatId, pilot: bool, out: *[l5_chips]u8) void {
    lfsr.gold(13, xa_taps, xb_taps, (if (pilot) xb_state_q5 else xb_state_i5)[sat.index], xa_restart, out);
}

pub fn l2cm(sat: SatId, out: *[l2cm_chips]u8) void {
    var r = Modular(27){ .state = l2cm_state[sat.index], .taps = l2c_taps };
    for (out) |*chip| chip.* = r.step();
}

pub fn l2cl(sat: SatId, out: *[l2cl_chips]u8) void {
    var r = Modular(27){ .state = l2cl_state[sat.index], .taps = l2c_taps };
    for (out) |*chip| chip.* = r.step();
}

pub fn l1c(sat: SatId, pilot: bool, out: *[l1c_chips]u8) void {
    const c = (if (pilot) l1c_pilot else l1c_data)[sat.index];
    const w: u32 = c.w;
    const p: u32 = c.p;
    for (out, 0..) |*chip, i| {
        const t: u32 = @intCast(i);
        chip.* = if (t + 1 < p) legendre_10223.weil(t, w) else if (t < p + 6) l1c_inserted[t + 1 - p] else legendre_10223.weil(t - 7, w);
    }
}

pub fn l1cSecondary(sat: SatId) *const [l1c_overlay_chips]u1 {
    return &l1c_overlay[sat.index];
}
