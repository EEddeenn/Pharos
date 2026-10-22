const spec = @import("domain/signals/model");
const codes = @import("domain/signals/codes/glonass");
const Spec = spec.Spec;
const Gain = spec.Gain;
const Code = spec.Code;

const freq_g1: u32 = 1_602_000_000;
const freq_g2: u32 = 1_246_000_000;

const g1_fdma_step_hz: u32 = 562_500;
const g2_fdma_step_hz: u32 = 437_500;

pub const plan_k_min: i32 = -7;
pub const plan_k_max: i32 = 6;

pub const rows = [_]Spec{ g1, g2 };

pub const g1: Spec = .{
    .signal = .g1,
    .observables = &.{.{ .code = "1C", .component = .data, .phase_reference = true }},
    .carrier = .{ .fdma = .{ .base_hz = freq_g1, .step_hz = g1_fdma_step_hz } },
    .code = Code.oneMs(codes.chips),
    .frame = .{ .nh_length = 10, .nh_code = 0, .frame_length_ms = 2000 },
    .family = .gnav,
    .modulation = .{ .data = Gain.real(1) },
};

pub const g2: Spec = .{
    .signal = .g2,
    .observables = &.{.{ .code = "2C", .component = .data, .phase_reference = true }},
    .carrier = .{ .fdma = .{ .base_hz = freq_g2, .step_hz = g2_fdma_step_hz } },
    .code = Code.oneMs(codes.chips),
    .frame = .{ .nh_length = 10, .nh_code = 0, .frame_length_ms = 2000 },
    .family = .gnav,
    .modulation = .{ .data = Gain.real(1) },
};
