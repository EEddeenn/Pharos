const spec = @import("domain/signals/model");
const codes = @import("domain/signals/codes/galileo");
const Spec = spec.Spec;
const Gain = spec.Gain;
const Code = spec.Code;

const freq_e1: u32 = 1_575_420_000;
const freq_e5a: u32 = 1_176_450_000;
const freq_e5b: u32 = 1_207_140_000;
const freq_e6: u32 = 1_278_750_000;

pub const rows = [_]Spec{ e1, e5a, e5b, e6 };

pub const e1: Spec = .{
    .signal = .e1,
    .observables = &.{.{ .code = "1C", .component = .pilot }},
    .carrier = .{ .fixed = freq_e1 },
    .code = .{ .chip_rate_hz = 1_023_000, .primary_chips = codes.e1_chips, .period_ms = 4, .entries_per_chip = 12 },
    .frame = .{ .nh_length = 1, .nh_code = 0, .frame_length_ms = 2000 },
    .frame_offset_ms = 1000,
    .secondary_length = codes.cs25.len,
    .family = .inav,
    .modulation = .{ .waveform = .{ .states = &.{ 0, 4, 0, 4, 0, 4, 7, 3, 7, 3, 7, 3 }, .values = &e1_values } },
};

const e1_values: [8]Gain = blk: {
    const data: f64 = @sqrt(5.0 / 11.0);
    const pilot: f64 = -@sqrt(5.0 / 11.0);
    const high: f64 = @sqrt(1.0 / 22.0);
    var values: [8]Gain = undefined;
    for (&values, 0..) |*value, state| {
        const d: f64 = if (state & 1 == 0) 1 else -1;
        const p: f64 = if (state & 2 == 0) 1 else -1;
        const relative: f64 = if (state & 4 == 0) 1 else -1;
        value.* = .{
            .re = d * data + p * pilot + relative * (d * high + p * high),
            .im = 0,
        };
    }
    break :blk values;
};

pub const e5a: Spec = .{
    .signal = .e5a,
    .observables = &.{.{ .code = "5Q", .component = .pilot }},
    .carrier = .{ .fixed = freq_e5a },
    .code = Code.oneMs(codes.e5a_chips),
    .frame = .{ .nh_length = 20, .nh_code = 0x97421, .frame_length_ms = 10000 },
    .secondary_length = codes.cs100_chips,
    .family = .fnav,
    .modulation = .{ .components = .{ .data = Gain.real(Gain.half_power_amplitude), .pilot = Gain.imag(Gain.half_power_amplitude) } },
};

pub const e5b: Spec = .{
    .signal = .e5b,
    .observables = &.{.{ .code = "7Q", .component = .pilot }},
    .carrier = .{ .fixed = freq_e5b },
    .code = Code.oneMs(codes.e5b_chips),
    .frame = .{ .nh_length = 4, .nh_code = 0x7, .frame_length_ms = 2000 },
    .secondary_length = codes.cs100_chips,
    .family = .inav,
    .modulation = .{ .components = .{ .data = Gain.real(Gain.half_power_amplitude), .pilot = Gain.imag(Gain.half_power_amplitude) } },
};

pub const e6: Spec = .{
    .signal = .e6,
    .observables = &.{.{ .code = "6C", .component = .pilot }},
    .carrier = .{ .fixed = freq_e6 },
    .code = .{ .chip_rate_hz = 5_115_000, .primary_chips = codes.e6_chips, .period_ms = 1 },
    .frame = .{ .nh_length = 1, .nh_code = 0, .frame_length_ms = 1000 },
    .secondary_length = codes.cs100_chips,
    .family = .cnav_has,
    .modulation = .{ .components = .{ .data = Gain.real(Gain.half_power_amplitude), .pilot = Gain.real(-Gain.half_power_amplitude) } },
};
