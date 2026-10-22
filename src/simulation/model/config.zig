const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const clock_reference = @import("domain/navigation/clock_reference");
const ionosphere_config = @import("simulation/model/ionosphere");
const sampling = @import("simulation/model/sampling");
const power = @import("simulation/model/power");
const System = gnss_types.System;
const Signal = gnss_types.Signal;
const SatSet = gnss_types.SatSet;
const GpsTime = @import("domain/time/gps").GpsTime;
pub const ClockRef = clock_reference.ClockRef;
pub const ClockReferences = clock_reference.ClockReferences;

pub const Config = struct {
    start: GpsTime,
    duration_ms: u64,
    has: ?Has,
    ppp_b2b: ?PppB2b,
    ionosphere: ionosphere_config.Configuration,
    signals: std.EnumSet(Signal),
    elevation_mask_rad: f64,
    mask_out: std.EnumArray(System, SatSet),
    samples: ?Samples,
    observation: ?Observation,
    position: ?Position,
    power: Power,
};

pub const max_service_interval_s: u32 = 3600;

pub const HasStatus = enum {
    test_mode,
    operational,

    pub const words: std.EnumArray(HasStatus, []const u8) = .init(.{ .test_mode = "test", .operational = "operational" });

    pub fn name(self: HasStatus) []const u8 {
        return words.get(self);
    }
};

pub const Has = struct {
    status: HasStatus,
    clock_interval_s: u32,
    orbit_interval_s: u32,
};

pub const PppB2b = struct {
    clock_interval_s: u32,
    orbit_interval_s: u32,
};

pub const SampleRate = sampling.SampleRate;
pub const Hz = sampling.Hz;
pub const IqFormat = sampling.IqFormat;

pub const Samples = struct {
    format: IqFormat,
    sample_rate: SampleRate,
    center: Hz,

    pub const max_rate_hz: u64 = 200_000_000;
    pub const max_center_hz: i64 = 6_000_000_000;
    const min_rate_hz: u64 = 1000;

    pub fn valid(self: Samples) bool {
        const hz = self.sample_rate.hz();
        if (!(hz >= min_rate_hz and hz <= max_rate_hz)) return false;
        if (self.format == .iq2 and self.sample_rate.samplesPerEpoch() % 2 != 0) return false;
        return self.center.hz >= 0 and self.center.hz <= max_center_hz;
    }

    pub fn inBand(self: Samples, carrier_hz: u64) bool {
        const offset: i64 = @as(i64, @intCast(carrier_hz)) - self.center.hz;
        return 2 * @abs(offset) <= self.sample_rate.hz();
    }
};

pub const Observation = struct {
    interval_ms: u32,
};

pub const PositionFormat = enum(u8) {
    ecef = 0,
    lla = 1,
    kml = 2,

    pub const words: std.EnumArray(PositionFormat, []const u8) = .init(.{ .ecef = "ECEF", .lla = "LLA", .kml = "KML" });

    pub fn extension(self: PositionFormat) []const u8 {
        return @tagName(self);
    }
};

pub const Position = struct {
    interval_ms: u32,
    format: PositionFormat,
};

pub const Power = power.Config;
