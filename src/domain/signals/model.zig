const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const physical = @import("domain/physical_constants");

const Signal = gnss_types.Signal;
const Component = gnss_types.Component;
const FreqId = gnss_types.FreqId;

const NavFamily = gnss_types.NavFamily;

pub const Gain = struct {
    re: f64,
    im: f64,

    pub const zero: Gain = .{ .re = 0, .im = 0 };

    pub const half_power_amplitude = 0.7071067811865475244;

    pub fn real(a: f64) Gain {
        return .{ .re = a, .im = 0 };
    }

    pub fn imag(a: f64) Gain {
        return .{ .re = 0, .im = a };
    }

    pub fn power(self: Gain) f64 {
        return self.re * self.re + self.im * self.im;
    }
};

pub const Waveform = struct {
    states: []const u8,
    values: []const Gain,
    pilot_bits: u8 = 0,
};

pub const Modulation = union(enum) {
    data: Gain,
    components: struct { data: Gain, pilot: Gain },
    tdm: struct { data: Gain, pilot: Gain, pilot_period_ms: u16 },
    waveform: Waveform,
};

pub const Observable = struct { code: *const [2]u8, component: Component, phase_reference: bool = false };

pub const max_observables = 2;

pub const FrameLayout = struct { nh_length: u8, nh_code: u32, frame_length_ms: u16 };

pub const Frame = struct {
    code_length_ms: u8,
    nh_length: u8,
    nh_code: u32,
    frame_length_ms: u16,

    fn bitLengthMs(self: Frame) u16 {
        return @as(u16, self.code_length_ms) * self.nh_length;
    }
};

pub const Carrier = union(enum) {
    fixed: u64,
    fdma: struct { base_hz: u64, step_hz: u32 },

    pub fn hz(self: Carrier, freq_id: ?FreqId) u64 {
        return switch (self) {
            .fixed => |f| f,
            .fdma => |p| blk: {
                const k: i64 = freq_id.?.int();
                break :blk @intCast(@as(i64, @intCast(p.base_hz)) + p.step_hz * k);
            },
        };
    }
};

pub const Code = struct {
    chip_rate_hz: u32,
    primary_chips: u32,
    period_ms: u16,
    entries_per_chip: u8 = 1,

    pub fn oneMs(chips: u32) Code {
        return .{ .chip_rate_hz = chips * 1000, .primary_chips = chips, .period_ms = 1 };
    }
};

pub const Spec = struct {
    signal: Signal,
    carrier: Carrier,
    code: Code,
    frame: FrameLayout,
    geo_frame: ?FrameLayout = null,
    frame_offset_ms: u16 = 0,
    secondary_length: u16 = 0,
    family: NavFamily,
    modulation: Modulation,
    observables: []const Observable,
    carrier_reference: ?Signal = null,

    pub fn carrierSignal(self: Spec) Signal {
        return self.carrier_reference orelse self.signal;
    }

    pub fn hasPilot(self: Spec) bool {
        return self.modulation != .data;
    }

    pub fn pilotCarriesBit(self: Spec) bool {
        return self.hasPilot() and self.modulation != .tdm;
    }

    pub fn pilotPeriodMs(self: Spec) u16 {
        return switch (self.modulation) {
            .tdm => |tdm| tdm.pilot_period_ms,
            else => self.code.period_ms,
        };
    }

    pub fn tdmPeriods(self: Spec) ?u16 {
        return if (self.modulation == .tdm) @divExact(self.modulation.tdm.pilot_period_ms, self.code.period_ms) else null;
    }

    pub fn entriesPerChip(self: Spec) u32 {
        return @as(u32, self.code.entries_per_chip) * @as(u32, if (self.modulation == .tdm) 2 else 1);
    }

    pub fn entriesPerMs(self: Spec) u32 {
        return self.code.chip_rate_hz * self.entriesPerChip() / 1000;
    }

    pub fn entriesPerPeriod(self: Spec) u32 {
        return self.entriesPerMs() * self.code.period_ms;
    }

    pub fn valueCount(self: Spec) usize {
        return switch (self.modulation) {
            .waveform => |waveform| waveform.values.len,
            else => 4,
        };
    }

    pub fn subcarrierStates(self: Spec) []const u8 {
        return switch (self.modulation) {
            .waveform => |waveform| waveform.states,
            else => &.{0},
        };
    }

    pub fn stateValue(self: Spec, state: usize) Gain {
        if (self.modulation == .waveform) return self.modulation.waveform.values[state];
        const d: f64 = if (state & 1 == 0) 1 else -1;
        const p: f64 = if (state & 2 == 0) 1 else -1;
        if (self.modulation == .tdm) {
            const gains = self.modulation.tdm;
            const g = if (state & 2 == 0) gains.data else gains.pilot;
            return .{ .re = d * g.re, .im = d * g.im };
        }
        const gains = switch (self.modulation) {
            .data => |gain| .{ gain, Gain.zero },
            .components => |components| .{ components.data, components.pilot },
            else => unreachable,
        };
        return .{ .re = d * gains[0].re + p * gains[1].re, .im = d * gains[0].im + p * gains[1].im };
    }

    pub fn power(self: Spec) f64 {
        if (self.modulation == .waveform) {
            const waveform = self.modulation.waveform;
            var sum: f64 = 0;
            for (waveform.states) |state| {
                for (0..4) |signs| sum += waveform.values[state ^ signs].power();
            }
            return sum / @as(f64, @floatFromInt(4 * waveform.states.len));
        }
        const gains = switch (self.modulation) {
            .data => |gain| .{ gain, Gain.zero },
            .components => |components| .{ components.data, components.pilot },
            .tdm => |tdm| .{ tdm.data, tdm.pilot },
            else => unreachable,
        };
        const both = gains[0].power() + gains[1].power();
        return if (self.modulation == .tdm) both / 2 else both;
    }

    pub fn stateBits(self: Spec, component: Component) u8 {
        if (self.modulation == .tdm) return 0;
        const pilot: u8 = switch (self.modulation) {
            .waveform => |waveform| waveform.pilot_bits,
            .components => 0b010,
            .data => 0,
            .tdm => unreachable,
        };
        if (pilot == 0) return 0;
        const all: u8 = @intCast(self.valueCount() - 1);
        return if (component == .pilot) pilot else all & ~pilot;
    }

    pub fn frameFor(self: Spec, geo: bool) Frame {
        const layout = if (geo) self.geo_frame orelse self.frame else self.frame;
        return .{ .code_length_ms = @intCast(self.code.period_ms), .nh_length = layout.nh_length, .nh_code = layout.nh_code, .frame_length_ms = layout.frame_length_ms };
    }

    pub fn carrierHz(self: Spec, freq_id: ?FreqId) u64 {
        return self.carrier.hz(freq_id);
    }

    pub fn wavelengthM(self: Spec, freq_id: ?FreqId) f64 {
        return physical.light_speed / @as(f64, @floatFromInt(self.carrierHz(freq_id)));
    }

    pub fn ionoFactor(self: Spec, freq_id: ?FreqId) f64 {
        const f1: f64 = physical.iono_reference_hz;
        const f: f64 = @floatFromInt(self.carrierHz(freq_id));
        return (f1 / f) * (f1 / f);
    }
};

const separation_tolerance = 1e-12;

pub fn check(comptime table: []const Spec) void {
    @setEvalBranchQuota(100_000);
    if (table.len != std.enums.values(Signal).len) @compileError("spec table must list every Signal");
    for (table, 0..) |s, i| {
        const label = "spec[" ++ s.signal.name() ++ "]";
        if (@backingInt(s.signal) != i) @compileError(label ++ ": table row out of enum order");
        if (s.carrier.hz(if (s.carrier == .fdma) FreqId{ .k = 0 } else null) == 0) @compileError(label ++ ": missing carrier frequency");

        const code = s.code;
        if (code.chip_rate_hz == 0 or code.primary_chips == 0 or code.entries_per_chip == 0) @compileError(label ++ ": incomplete code row");
        if ((code.chip_rate_hz * s.entriesPerChip()) % 1000 != 0) @compileError(label ++ ": entries per millisecond is not an integer");
        if (code.period_ms == 0 or s.pilotPeriodMs() % code.period_ms != 0) @compileError(label ++ ": pilot period must be a multiple of the data period");
        if (@as(u64, code.chip_rate_hz) * code.period_ms != @as(u64, code.primary_chips) * time.ms_per_second) @compileError(label ++ ": primary code length disagrees with its chip rate and period");
        const period_ms = scalePeriodMs(s.signal.system());
        if (period_ms % code.period_ms != 0 or (s.modulation == .tdm and period_ms % s.pilotPeriodMs() != 0)) @compileError(label ++ ": code period does not divide the scale period");

        checkFrame(label, s.frameFor(false), period_ms);
        if (s.geo_frame != null) checkFrame(label ++ " GEO", s.frameFor(true), period_ms);

        if (s.secondary_length != 0) {
            if (!s.hasPilot()) @compileError(label ++ ": secondary code without a pilot channel");
            if (period_ms % (@as(u32, s.secondary_length) * s.pilotPeriodMs()) != 0) @compileError(label ++ ": secondary code cycle does not divide the scale period");
        }

        if (s.modulation == .waveform) {
            const w = s.modulation.waveform;
            if (w.states.len == 0 or (w.values.len != 4 and w.values.len != 8)) @compileError(label ++ ": incomplete waveform");
            if (s.entriesPerPeriod() % w.states.len != 0) @compileError(label ++ ": waveform pattern does not divide the code period");
            for (w.states) |state| {
                if (state >= w.values.len) @compileError(label ++ ": waveform state exceeds its value table");
            }
        } else if (switch (s.modulation) {
            .data => |gain| gain.power(),
            .components => |gains| gains.data.power(),
            .tdm => |gains| gains.data.power(),
            .waveform => unreachable,
        } == 0) @compileError(label ++ ": data channel must have a non-zero gain");

        if (s.carrier_reference) |ref| {
            const r = table[@backingInt(ref)];
            if (ref.system() != s.signal.system() or !std.meta.eql(r.carrier, s.carrier) or r.carrier_reference != null) @compileError(label ++ ": the carrier reference is not a reference row of the system on the same carrier");
        }

        checkComponents(label, s);
        for (table[0..i]) |other| {
            if (other.signal.system() != s.signal.system()) continue;
            for (other.observables) |a| for (s.observables) |b| {
                if (std.mem.eql(u8, a.code, b.code)) @compileError(label ++ ": observation code " ++ b.code ++ " repeats in its system");
            };
        }
    }
}

fn scalePeriodMs(system: gnss_types.System) u32 {
    return switch (system) {
        .gps, .bds, .gal => time.ms_per_week,
        .glo => time.ms_per_day,
    };
}

fn checkFrame(comptime label: []const u8, comptime frame: Frame, comptime period_ms: u32) void {
    const bit_ms = frame.bitLengthMs();
    if (bit_ms == 0) @compileError(label ++ ": bit length is zero");
    if (frame.frame_length_ms % bit_ms != 0) @compileError(label ++ ": frame is not a whole number of bits");
    if (frame.nh_length >= 32) @compileError(label ++ ": NH length must fit the u32 code");
    if (frame.nh_code >= (@as(u64, 1) << frame.nh_length)) @compileError(label ++ ": NH code wider than NH length");
    if (period_ms % frame.frame_length_ms != 0) @compileError(label ++ ": frame length does not divide the scale period");
}

fn checkComponents(comptime label: []const u8, comptime s: Spec) void {
    if (s.observables.len == 0 or s.observables.len > max_observables) @compileError(label ++ ": one or two observation codes");
    for (s.observables) |o| {
        if (o.component == .pilot and !s.hasPilot()) @compileError(label ++ ": a pilot observation code without a pilot");
    }
    const pilot = s.stateBits(.pilot);
    if (pilot == 0) return;
    if (pilot & 1 != 0) @compileError(label ++ ": bit 0 is the data component's");
    const v0 = s.stateValue(0);
    for (0..s.valueCount()) |state| {
        const v = s.stateValue(state);
        const d = s.stateValue(state & ~@as(usize, pilot));
        const p = s.stateValue(state & pilot);
        if (@abs(d.re + p.re - v0.re - v.re) > separation_tolerance or @abs(d.im + p.im - v0.im - v.im) > separation_tolerance) {
            @compileError(label ++ ": the values do not separate into data and pilot parts");
        }
    }
}
