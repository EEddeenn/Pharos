const spec = @import("../../core.zig").spec;
const codes = @import("codes.zig");
const Spec = spec.Spec;
const Gain = spec.Gain;
const Code = spec.Code;
const Frame = spec.Frame;

const freq_b1c: u32 = 1_575_420_000;
const freq_b1i: u32 = 1_561_098_000;
const freq_b2i: u32 = 1_207_140_000;
const freq_b3i: u32 = 1_268_520_000;
const freq_b2a: u32 = 1_176_450_000;
const freq_b2b: u32 = 1_207_140_000;

const d1_frame: Frame = .{ .code_length_ms = 1, .nh_length = 20, .nh_code = 0x72b20, .frame_length_ms = 6000 };
const d2_frame: Frame = .{ .code_length_ms = 1, .nh_length = 2, .nh_code = 0, .frame_length_ms = 600 };

pub const rows = [_]Spec{ b1c, b1i, b2i, b3i, b2a, b2b };

const b1c: Spec = .{
    .signal = .b1c,
    .observables = &.{ .{ .code = "1D", .component = .data, .phase_reference = true }, .{ .code = "1P", .component = .pilot } },
    .carrier = .{ .fixed = freq_b1c },
    .code = .{ .chip_rate_hz = 1_023_000, .primary_chips = codes.b1c_chips, .data_period_ms = 10, .pilot_period_ms = 10, .entries_per_chip = 12 },
    .frame = .{ .code_length_ms = 10, .nh_length = 1, .nh_code = 0, .frame_length_ms = 18000 },
    .secondary_length = codes.b1c_secondary_chips,
    .family = .bcnav1,
    .waveform = .{ .states = &b1c_subcarrier, .values = &b1c_values, .has_pilot = true, .pilot_bits = 0b110 },
    .pilot_carries_bit = true,
};

const b1c_subcarrier = [_]u8{ 0, 4, 0, 4, 0, 4, 7, 3, 7, 3, 7, 3 };

const b1c_values: [8]Gain = blk: {
    const data: f64 = 0.5;
    const pilot: f64 = @sqrt(29.0 / 44.0);
    const high_pilot: f64 = @sqrt(1.0 / 11.0);
    var values: [8]Gain = undefined;
    for (&values, 0..) |*value, state| {
        const d: f64 = if (state & 1 == 0) 1 else -1;
        const p: f64 = if (state & 2 == 0) 1 else -1;
        const relative: f64 = if (state & 4 == 0) 1 else -1;
        value.* = .{
            .re = d * data + relative * (p * high_pilot),
            .im = p * pilot,
        };
    }
    break :blk values;
};

const b1i: Spec = .{
    .signal = .b1i,
    .observables = &.{.{ .code = "2I", .component = .data, .phase_reference = true }},
    .carrier = .{ .fixed = freq_b1i },
    .code = Code.oneMs(codes.b1i_chips),
    .frame = d1_frame,
    .geo_frame = d2_frame,
    .family = .d1d2,
    .data_gain = Gain.real(1),
};

const b2i: Spec = .{
    .signal = .b2i,
    .observables = &.{.{ .code = "7I", .component = .data, .phase_reference = true }},
    .carrier = .{ .fixed = freq_b2i },
    .code = Code.oneMs(codes.b1i_chips),
    .frame = d1_frame,
    .geo_frame = d2_frame,
    .family = .d1d2,
    .data_gain = Gain.real(1),
};

const b3i: Spec = .{
    .signal = .b3i,
    .observables = &.{.{ .code = "6I", .component = .data, .phase_reference = true }},
    .carrier = .{ .fixed = freq_b3i },
    .code = Code.oneMs(codes.b3i_chips),
    .frame = d1_frame,
    .geo_frame = d2_frame,
    .family = .d1d2,
    .data_gain = Gain.real(1),
};

const b2a: Spec = .{
    .signal = .b2a,
    .observables = &.{ .{ .code = "5D", .component = .data, .phase_reference = true }, .{ .code = "5P", .component = .pilot } },
    .carrier = .{ .fixed = freq_b2a },
    .code = Code.oneMs(codes.b2a_chips),
    .frame = .{ .code_length_ms = 1, .nh_length = 5, .nh_code = 0x8, .frame_length_ms = 3000 },
    .secondary_length = codes.b2a_secondary_chips,
    .family = .bcnav2,
    .data_gain = Gain.real(Gain.half_power_amplitude),
    .pilot_gain = Gain.imag(Gain.half_power_amplitude),
    .pilot_carries_bit = true,
};

const b2b: Spec = .{
    .signal = .b2b,
    .observables = &.{.{ .code = "7D", .component = .data, .phase_reference = true }},
    .carrier = .{ .fixed = freq_b2b },
    .code = Code.oneMs(codes.b2b_chips),
    .frame = .{ .code_length_ms = 1, .nh_length = 1, .nh_code = 0, .frame_length_ms = 1000 },
    .family = .bcnav3,
    .data_gain = Gain.real(Gain.half_power_amplitude),
};
