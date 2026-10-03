const std = @import("std");
const rotor = @import("rotor.zig");
const time = @import("shared").core.time;
const types = @import("shared").core.types;
const civil = @import("shared").core.civil;

pub const sample_stride: u32 = rotor.stride;

const mask_slack_periods: usize = 2;

const ms_per_second: f64 = time.ms_per_second;

pub const EpochParams = struct {
    carrier_phase0: f64,
    carrier_step: f64,
    entry_phase0: f64,
    entries_per_sample: f64,
    period0: u64,
    table: u32,
    amp: f32,
    masks: []const u8,
    lead_bits: u8 = 0,
    lead_entries: f64 = 0,

    pub fn masksNeeded(self: EpochParams, samples_per_epoch: u32, entries_per_period: u32) usize {
        const strided = std.mem.alignForward(u32, samples_per_epoch, sample_stride);
        const end = self.entry_phase0 + @as(f64, @floatFromInt(strided)) * self.entries_per_sample + self.lead_entries;
        return @as(usize, @intFromFloat(@floor(end / @as(f64, @floatFromInt(entries_per_period))))) + mask_slack_periods;
    }
};

pub const Endpoint = struct {
    phase_cycles: f64,
    tx: time.GpsTime,
};

pub const ChannelConstants = struct {
    if_hz: i64,
    code_ms: u16,
    entries_per_ms: u32,
    scale: types.System,
    table: u32,
};

fn ifPhase(if_hz: i64, t: time.GpsTime) f64 {
    const numerator = @mod(@mod(if_hz, time.ms_per_second) * @mod(t.ms, time.ms_per_second), time.ms_per_second);
    const whole = @as(f64, @floatFromInt(numerator)) / ms_per_second;
    return @mod(whole + @as(f64, @floatFromInt(if_hz)) * t.sub_ms / ms_per_second, 1.0);
}

pub fn leadEntries(ch: ChannelConstants, late_s: f64, early_s: f64) f64 {
    return (late_s - early_s) * ms_per_second * @as(f64, @floatFromInt(ch.entries_per_ms));
}

fn amplitude(cn0_dbhz: f64, n: f64) f32 {
    const fs = ms_per_second * n;
    return @floatCast(@sqrt(2.0 * std.math.pow(f64, 10.0, cn0_dbhz / 10.0) / fs));
}

pub const max_rate_deviation: f64 = 0.03;

pub fn derive(ch: ChannelConstants, leap: civil.Leap, a: Endpoint, b: Endpoint, t_rx: time.GpsTime, samples_per_epoch: u32, cn0_dbhz: f64) ?EpochParams {
    const n: f64 = @floatFromInt(samples_per_epoch);
    const base_ms = a.tx.baseMs(ch.scale, leap);
    const span_ms = @as(f64, @floatFromInt(b.tx.ms - a.tx.ms)) + (b.tx.sub_ms - a.tx.sub_ms);
    if (!(@abs(span_ms - 1.0) <= max_rate_deviation) or base_ms < 0) return null;
    const period0 = @divFloor(base_ms, ch.code_ms);
    const in_period: f64 = @as(f64, @floatFromInt(@mod(base_ms, ch.code_ms))) + a.tx.sub_ms;
    const epm: f64 = @floatFromInt(ch.entries_per_ms);
    const phase0 = ifPhase(ch.if_hz, t_rx) - a.phase_cycles;
    return .{
        .carrier_phase0 = phase0 - @floor(phase0),
        .carrier_step = @as(f64, @floatFromInt(ch.if_hz)) / (n * ms_per_second) + (a.phase_cycles - b.phase_cycles) / n,
        .entry_phase0 = in_period * epm,
        .entries_per_sample = span_ms * epm / n,
        .period0 = @intCast(period0),
        .table = ch.table,
        .amp = amplitude(cn0_dbhz, n),
        .masks = &.{},
    };
}
