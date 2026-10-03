const std = @import("std");
const core = @import("../core.zig");
const System = core.types.System;
const Signal = core.types.Signal;
const SatSet = core.types.SatSet;
const GpsTime = core.time.GpsTime;
const dictionary = core.dictionary;
const command = @import("command.zig");
const PowerEntry = command.PowerEntry;
const gnss = @import("../gnss.zig");
pub const ClockRef = gnss.delay.ClockRef;
pub const Messages = @import("messages.zig").Messages;

pub const max_power_entries: usize = 100_000;

fn within(v: f64, range: [2]f64) bool {
    return v >= range[0] and v <= range[1];
}

pub const Scenario = struct {
    name: []const u8,
    start: GpsTime,
    trajectory_file: []const u8,
    duration_ms: u64,
    nav_files: []const NavFile,
    antenna: ?[]const u8,
    precise: ?Precise,
    has: ?Has,
    ppp_b2b: ?PppB2b,
    ionosphere: @import("ionosphere.zig").Configuration,
    messages: Messages = .{},
    signals: std.EnumSet(Signal),
    elevation_mask_rad: f64,
    mask_out: std.EnumArray(System, SatSet),
    samples: ?Samples,
    observation: ?Observation,
    position: ?Position,
    power: Power,

    const max_start_ms: i64 = 1 << 46;

    pub fn carries(self: anytype, family: core.types.NavFamily) bool {
        var it = self.signals.iterator();
        while (it.next()) |signal| if (gnss.spec.get(signal).family == family) return true;
        return false;
    }

    pub fn enabledSystems(self: anytype) std.EnumSet(System) {
        var systems: std.EnumSet(System) = .empty;
        var it = self.signals.iterator();
        while (it.next()) |signal| systems.insert(signal.system());
        return systems;
    }

    pub fn listedSignalOf(self: anytype, sat: core.types.SatId) ?Signal {
        var it = self.signals.iterator();
        while (it.next()) |signal| if (gnss.allocation.transmits(sat, signal, self.start)) return signal;
        return null;
    }

    pub fn transmitsListed(self: anytype, sat: core.types.SatId) bool {
        return !self.mask_out.get(sat.system).contains(sat) and self.listedSignalOf(sat) != null;
    }

    pub fn validate(self: *const Scenario) ?[]const u8 {
        if (self.start.ms < 0 or self.start.ms >= max_start_ms or
            !(self.start.sub_ms >= 0 and self.start.sub_ms < 1))
        {
            return "the scenario start is outside the millisecond range";
        }
        if (!self.messages.ordered()) return "the message publications are not in order, or two overlap";

        const active = self.samples != null or self.observation != null;
        if (active != (self.ionosphere == .ready)) return "the ionosphere configuration does not match the scenario outputs";
        if (self.ionosphere == .ready and !self.ionosphere.ready.valid()) return "the ionosphere coefficients or source do not fit the resolved model";
        if (self.ionosphere == .ready and self.ionosphere.ready.requested == .auto) {
            const enabled = self.enabledSystems();
            for (System.all) |system| {
                if (enabled.contains(system) == (self.ionosphere.ready.systems.get(system).model == .none)) return "the automatic ionosphere models do not match the listed signals' systems";
            }
        }

        if (self.duration_ms == 0) return "the run is shorter than one epoch";
        if (!(@abs(self.elevation_mask_rad) <= command.max_elevation_mask_rad)) return "the elevation mask is outside a quarter turn";
        if (self.samples) |s| if (!s.valid()) return "the samples block's rate, format or centre is outside its range";
        if (self.observation) |o| if (o.interval_ms == 0) return "observation.interval is zero";
        if (self.position) |p| if (p.interval_ms == 0) return "position.interval is zero";
        if (self.has) |h| {
            if (!serviceInterval(h.clock_interval_s) or !serviceInterval(h.orbit_interval_s)) return "a HAS interval is outside 1 to 3600 s";
        }
        if (self.ppp_b2b) |p| {
            if (!serviceInterval(p.clock_interval_s) or !serviceInterval(p.orbit_interval_s)) return "a PPP-B2b interval is outside 1 to 3600 s";
        }

        const power = self.power;
        if (!within(power.noise_floor_dbm_hz, command.noise_floor_range)) return "the noise floor is outside its range";
        if (!within(power.init_cn0_dbhz, command.cn0_range)) return "the initial C/N0 is outside its range";
        if (power.schedule.len > max_power_entries) return "the power schedule holds more entries than its limit";
        var previous_epoch: u64 = 0;
        for (power.schedule) |e| {
            if (e.at_epoch < previous_epoch) return "the power schedule is not in epoch order";
            previous_epoch = e.at_epoch;
            if (e.target == .sat and !e.target.sat.valid()) return "a power entry names a satellite its system does not have";
            if (e.level) |l| if (!within(l.cn0(power.noise_floor_dbm_hz), command.cn0_range)) return "a power entry's C/N0 is outside its range";
        }
        return null;
    }
};

pub const max_service_interval_s: u32 = 3600;

fn serviceInterval(s: u32) bool {
    return s >= 1 and s <= max_service_interval_s;
}

pub const NavFile = struct {
    path: []const u8,
    kind: NavKind,
};

pub const NavKind = enum {
    ephemeris,
    almanac,

    pub const words = dictionary.tagNames(NavKind);
};

pub const Precise = struct {
    orbit: []const []const u8,
    clock: []const []const u8,
    clock_reference: std.EnumArray(System, ClockRef),
};

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

pub const IonoModel = @import("ionosphere.zig").Model;
pub const IonoSelection = @import("ionosphere.zig").Selection;

pub const SampleRate = core.types.SampleRate;
pub const Hz = core.types.Hz;
pub const IqFormat = core.types.IqFormat;

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

pub const Power = struct {
    noise_floor_dbm_hz: f64,
    init_cn0_dbhz: f64,
    elevation_fade: bool,
    schedule: []const PowerEntry,
};
