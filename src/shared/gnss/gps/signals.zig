const spec = @import("../../core.zig").spec;
const codes = @import("codes.zig");
const Spec = spec.Spec;
const Gain = spec.Gain;
const Code = spec.Code;

const freq_l1: u32 = 1_575_420_000;
const freq_l2: u32 = 1_227_600_000;
const freq_l5: u32 = 1_176_450_000;

pub const rows = [_]Spec{ l1ca, l1c, l2c, l5 };

const l1ca: Spec = .{
    .signal = .l1ca,
    .observables = &.{.{ .code = "1C", .component = .data, .phase_reference = true }},
    .carrier = .{ .fixed = freq_l1 },
    .code = Code.oneMs(codes.l1ca_chips),
    .frame = .{ .code_length_ms = 1, .nh_length = 20, .nh_code = 0, .frame_length_ms = 6000 },
    .family = .lnav,
    .data_gain = Gain.real(1),
};

const l1c: Spec = .{
    .signal = .l1c,
    .observables = &.{ .{ .code = "1S", .component = .data }, .{ .code = "1L", .component = .pilot } },
    .carrier = .{ .fixed = freq_l1 },
    .carrier_reference = .l1ca,
    .code = .{ .chip_rate_hz = 1_023_000, .primary_chips = codes.l1c_chips, .data_period_ms = 10, .pilot_period_ms = 10, .entries_per_chip = 12 },
    .frame = .{ .code_length_ms = 10, .nh_length = 1, .nh_code = 0, .frame_length_ms = 18000 },
    .secondary_length = codes.l1c_overlay_chips,
    .family = .cnav2,
    .waveform = .{ .states = &l1c_subcarrier, .values = &l1c_values, .has_pilot = true, .pilot_bits = 0b010 },
    .pilot_carries_bit = true,
};

const l1c_subcarrier: [33 * 12]u8 = blk: {
    var states: [33 * 12]u8 = undefined;
    for (&states, 0..) |*state, e| {
        const data: u8 = if (e % 12 < 6) 0 else 1;
        const pilot: u8 = switch (e / 12) {
            0, 4, 6, 29 => if (e % 2 == 0) 0 else 1,
            else => data,
        };
        state.* = data | (pilot << 1);
    }
    break :blk states;
};

const l1c_values: [4]Gain = blk: {
    const data: f64 = -0.5;
    const pilot: f64 = -@sqrt(3.0 / 4.0);
    var values: [4]Gain = undefined;
    for (&values, 0..) |*value, state| {
        const d: f64 = if (state & 1 == 0) 1 else -1;
        const p: f64 = if (state & 2 == 0) 1 else -1;
        value.* = Gain.imag(d * data + p * pilot);
    }
    break :blk values;
};

pub const l2c: Spec = .{
    .signal = .l2c,
    .observables = &.{.{ .code = "2L", .component = .pilot }},
    .carrier = .{ .fixed = freq_l2 },
    .code = .{ .chip_rate_hz = 511_500, .primary_chips = codes.l2cm_chips, .data_period_ms = 20, .pilot_period_ms = 1500, .tdm_periods_per_cycle = 75 },
    .frame = .{ .code_length_ms = 20, .nh_length = 1, .nh_code = 0, .frame_length_ms = 12000 },
    .family = .cnav,
    .data_gain = Gain.imag(-1),
    .pilot_gain = Gain.imag(-1),
    .pilot_carries_bit = false,
};

pub const l5: Spec = .{
    .signal = .l5,
    .observables = &.{ .{ .code = "5I", .component = .data, .phase_reference = true }, .{ .code = "5Q", .component = .pilot } },
    .carrier = .{ .fixed = freq_l5 },
    .code = Code.oneMs(codes.l5_chips),
    .frame = .{ .code_length_ms = 1, .nh_length = 10, .nh_code = 0x2b0, .frame_length_ms = 6000 },
    .secondary_length = codes.nh20.len,
    .family = .cnav,
    .data_gain = Gain.real(Gain.half_power_amplitude),
    .pilot_gain = Gain.imag(-Gain.half_power_amplitude),
    .pilot_carries_bit = true,
};
