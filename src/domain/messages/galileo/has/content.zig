const std = @import("std");
const gnss_types = @import("domain/gnss_types");
pub const sat_mask_bits = 40;
pub const sig_mask_bits = 16;
pub const Gnss = enum(u4) { gps = 0, galileo = 2 };
pub const Validity = enum(u4) {
    s5 = 0,
    s10 = 1,
    s15 = 2,
    s20 = 3,
    s30 = 4,
    s60 = 5,
    s90 = 6,
    s120 = 7,
    s180 = 8,
    s240 = 9,
    s300 = 10,
    s600 = 11,
    s900 = 12,
    s1800 = 13,
    s3600 = 14,
    reserved = 15,

    pub fn seconds(self: Validity) ?u32 {
        return switch (self) {
            .s5 => 5,
            .s10 => 10,
            .s15 => 15,
            .s20 => 20,
            .s30 => 30,
            .s60 => 60,
            .s90 => 90,
            .s120 => 120,
            .s180 => 180,
            .s240 => 240,
            .s300 => 300,
            .s600 => 600,
            .s900 => 900,
            .s1800 => 1800,
            .s3600 => 3600,
            .reserved => null,
        };
    }
};

pub const Cell = struct { index: u4, signal: gnss_types.Signal, component: gnss_types.Component };
pub const gps_cells = [_]Cell{
    .{ .index = 0, .signal = .l1ca, .component = .data },
    .{ .index = 3, .signal = .l1c, .component = .data },
    .{ .index = 4, .signal = .l1c, .component = .pilot },
    .{ .index = 6, .signal = .l2c, .component = .data },
    .{ .index = 7, .signal = .l2c, .component = .pilot },
    .{ .index = 11, .signal = .l5, .component = .data },
    .{ .index = 12, .signal = .l5, .component = .pilot },
};

pub const galileo_cells = [_]Cell{
    .{ .index = 0, .signal = .e1, .component = .data },
    .{ .index = 1, .signal = .e1, .component = .pilot },
    .{ .index = 3, .signal = .e5a, .component = .data },
    .{ .index = 4, .signal = .e5a, .component = .pilot },
    .{ .index = 6, .signal = .e5b, .component = .data },
    .{ .index = 7, .signal = .e5b, .component = .pilot },
    .{ .index = 12, .signal = .e6, .component = .data },
    .{ .index = 13, .signal = .e6, .component = .pilot },
};

pub const SystemMask = struct {
    gnss: Gnss,
    sats: [sat_mask_bits]bool,
    sigs: [sig_mask_bits]bool,
    cells: ?[]const bool,
    nav_message: u3,

    pub fn satCount(self: SystemMask) usize {
        return std.mem.countScalar(bool, &self.sats, true);
    }

    pub fn sigCount(self: SystemMask) usize {
        return std.mem.countScalar(bool, &self.sigs, true);
    }

    pub fn cellCount(self: SystemMask) usize {
        if (self.cells) |c| return std.mem.countScalar(bool, c, true);
        return self.satCount() * self.sigCount();
    }
};

pub const Mask = struct {
    systems: []const SystemMask,

    pub fn satCount(self: Mask) usize {
        var n: usize = 0;
        for (self.systems) |s| n += s.satCount();
        return n;
    }

    pub fn cellCount(self: Mask) usize {
        var n: usize = 0;
        for (self.systems) |s| n += s.cellCount();
        return n;
    }
};

pub const Orbit = struct { iod: u16, radial_m: ?f64, in_track_m: ?f64, cross_m: ?f64 };
pub const Clock = union(enum) {
    value_m: f64,
    not_available,
    do_not_use,
};

const ClockSubset = struct {
    gnss: Gnss,
    multiplier: u2,
    selected: []const bool,
    values: []const Clock,
};

pub const PhaseBias = struct { cycles: f64, discontinuity: u2 };
pub const OrbitBlock = struct { validity: Validity, sats: []const Orbit };
pub const ClockFullBlock = struct { validity: Validity, multipliers: []const u2, sats: []const Clock };
pub const ClockSubsetBlock = struct { validity: Validity, systems: []const ClockSubset };
pub const CodeBiasBlock = struct { validity: Validity, cells: []const ?f64 };
pub const PhaseBiasBlock = struct { validity: Validity, cells: []const ?PhaseBias };
pub const Message = struct {
    toh: u12,
    mask_id: u5,
    iod_set_id: u5,
    mask: ?Mask = null,
    orbit: ?OrbitBlock = null,
    clock_full: ?ClockFullBlock = null,
    clock_subset: ?ClockSubsetBlock = null,
    code_bias: ?CodeBiasBlock = null,
    phase_bias: ?PhaseBiasBlock = null,
};

pub const Status = enum(u2) { test_mode = 0, operational = 1, reserved = 2, do_not_use = 3 };
pub const Header = struct {
    status: Status,
    message_type: u2 = 1,
    message_id: u5,
    size: u6,
    page_id: u8,
};

pub const PageRequest = struct { prn: u8, index: i64 };
pub const PagePayload = struct { header: Header, body: [53]u8 };
