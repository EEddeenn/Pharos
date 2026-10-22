const std = @import("std");
const cli_console = @import("interface/cli/console");
const diagnostics = @import("base/diagnostics");
const ionosphere_state = @import("simulation/state/ionosphere");
const scenario_signals = @import("simulation/model/signals");
const prepared_scenario = @import("simulation/model/prepared_scenario");
const prepared_bundle = @import("phb/prepared");
const civil = @import("domain/time/civil");

const Io = std.Io;
const Console = cli_console.Console;
const Escaped = diagnostics.Escaped;
const Number = @import("base/text/number").Number;
const Trajectory = @import("domain/trajectory/trajectory").Trajectory;
const Span = prepared_scenario.Span;
const Config = @import("simulation/model/config").Config;

/// Coefficients as a line lists them: each as `Number` writes it, a space between.
const Values = struct {
    values: []const f64,

    pub fn format(self: Values, w: *Io.Writer) Io.Writer.Error!void {
        for (self.values, 0..) |v, i| try w.print("{s}{f}", .{ if (i == 0) "" else " ", Number{ .value = v } });
    }
};

pub fn reportTrajectory(console: Console, traj: *const Trajectory, file: []const u8) void {
    const plural = if (traj.knots.len == 1) "" else "s";
    if (traj.name.len > 0) {
        console.info("Trajectory {f} ({f}): {d} knot{s} over {f} s", .{ Escaped{ .text = traj.name }, Escaped{ .text = file }, traj.knots.len, plural, Number{ .value = traj.duration() } });
    } else console.info("Trajectory {f}: {d} knot{s} over {f} s", .{ Escaped{ .text = file }, traj.knots.len, plural, Number{ .value = traj.duration() } });
}

pub fn reportSpan(console: Console, span: Span, leap: civil.Leap) void {
    const gps = span.start.printed(null);
    const utc = span.start.printed(leap);
    if (span.leap_change) |at| {
        console.info("Run: {d} ms from {f}, {f}; leap seconds {d}, then {d} from {f}", .{ span.epochs, gps, utc, span.leap_seconds, span.leap_seconds_after, at.printed(null) });
    } else console.info("Run: {d} ms from {f}, {f}; leap seconds {d}", .{ span.epochs, gps, utc, span.leap_seconds });
}

pub fn reportNavigation(console: Console, b: *const prepared_bundle.PreparedBundle) void {
    const display = &b.display;
    console.info("Navigation data: {d} Keplerian and {d} GLONASS records", .{ display.ephemerides.kepler.len, display.ephemerides.glonass.len });
    reportAntenna(console, b);
    if (b.scenario.precise) |product| console.info("Precise product: {d} satellites at {f} s", .{ product.series.len, Number{ .value = product.interval_s } });
}

pub fn reportCoverage(console: Console, b: *const prepared_scenario.PreparedScenario) void {
    for (b.flight_plan.timelines) |timeline| {
        if (scenario_signals.listedSignal(b.config.signals, b.config.start, timeline.sat) != null) break;
    } else return;
    const covered = b.flight_plan.coveredMs(&b.config, null);
    if (covered >= b.epochs()) return;
    // Whole milliseconds, so every digit, as an integer is written.
    console.warn("No satellite flies a listed signal from {d} s into the run: nothing is transmitted from there on", .{@as(f64, @floatFromInt(covered)) / 1000.0});
}

pub fn reportServices(console: Console, s: *const Config) void {
    if (s.has) |h| console.info("HAS MT1 on E6-B: status {s}, clocks every {d} s, orbits and biases every {d} s", .{ h.status.name(), h.clock_interval_s, h.orbit_interval_s });
    if (s.ppp_b2b) |p| console.info("PPP-B2b on the BDS-3 GEO B2b: clocks every {d} s, orbit cycles of {d} s", .{ p.clock_interval_s, p.orbit_interval_s });
}

pub fn printIonosphere(console: Console, info: ionosphere_state.Info) void {
    const resolved = info.resolved;
    console.info("Ionosphere: {s}", .{resolved.requested.name()});
    var enabled = info.enabled.iterator();
    while (enabled.next()) |system| {
        const applied = resolved.systems.get(system);
        const origin: []const u8 = switch (applied.source) {
            .scenario => "the scenario",
            .navigation => "the navigation data",
            .built_in => "the built-in set",
            .none => "",
        };
        switch (applied.model) {
            .none => console.info("Ionosphere {s}: none", .{system.name()}),
            .klobuchar => {
                const coefficients = resolved.broadcast.klobuchar;
                const name: []const u8 = if (resolved.requested == .auto and system == .glo) "Klobuchar substitute" else "Klobuchar";
                console.info("Ionosphere {s}: {s}, alpha {f}, beta {f} ({s})", .{ system.name(), name, Values{ .values = &coefficients.alpha }, Values{ .values = &coefficients.beta }, origin });
            },
            .bds_klobuchar => {
                const coefficients = resolved.broadcast.bds_klobuchar;
                console.info("Ionosphere {s}: BDS Klobuchar, alpha {f}, beta {f} ({s})", .{ system.name(), Values{ .values = &coefficients.alpha }, Values{ .values = &coefficients.beta }, origin });
            },
            .nequick => {
                const coefficients = resolved.broadcast.nequick.?;
                console.info("Ionosphere {s}: NeQuick G, ai0 {f} ai1 {f} ai2 {f} ({s})", .{ system.name(), Number{ .value = coefficients.ai0 }, Number{ .value = coefficients.ai1 }, Number{ .value = coefficients.ai2 }, origin });
            },
            .bdgim => console.info("Ionosphere {s}: BDGIM, alpha {f} TECu ({s})", .{ system.name(), Values{ .values = &resolved.broadcast.bdgim.? }, origin }),
        }
    }
}

fn reportAntenna(console: Console, b: *const prepared_bundle.PreparedBundle) void {
    if (b.display.names.antenna == null) return;
    const scenario = &b.scenario;
    var with: usize = 0;
    var without: usize = 0;
    for (scenario.flight_plan.timelines) |timeline| {
        if (scenario.phase_centres.at(timeline.sat, scenario.config.start) == null) without += 1 else with += 1;
    }
    console.info("Antenna offsets: {d} satellites with a phase centre per band, {d} without", .{ with, without });
}
