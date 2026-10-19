const std = @import("std");
const types = @import("shared").core.types;
const iono = @import("shared").core.iono;
const ModelKind = @import("shared").bundle.ionosphere.Model;
const Bundle = @import("shared").bundle.Bundle;
const Run = @import("../engine.zig").run.Run;

pub const Host = struct { start_time: []const u8, run_id: []const u8, file: []const u8 };

const max_parameters = ModelKind.bdgim.parameterCount();

const SignalEntry = struct { signal: []const u8, system: []const u8 };
const IonosphereSystemDocument = struct { system: []const u8, model: []const u8, parameters: []const f64, source: []const u8 };
const IonosphereDocument = struct { model: []const u8, parameters: []const f64, systems: []const IonosphereSystemDocument };
const PreciseDocument = struct { clock: []const []const u8, orbit: []const []const u8, phase_centre: []const u8 };
const HasDocument = struct { clock_interval_s: u32, orbit_interval_s: u32, status: []const u8 };
const PppB2bDocument = struct { clock_interval_s: u32, orbit_interval_s: u32 };
const Document = struct {
    antenna: ?[]const u8,
    ionosphere: IonosphereDocument,
    navigation: []const []const u8,
    output: struct { center_freq_mhz: f64, duration_ms: u64, file: []const u8, first_epoch: u64, format: []const u8, sample_freq_mhz: f64, size_bytes: u64 },
    precise: ?PreciseDocument,
    run_id: []const u8,
    scenario_name: []const u8,
    services: struct { has: ?HasDocument, ppp_b2b: ?PppB2bDocument },
    signals: []const SignalEntry,
    start_time: []const u8,
};

pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, b: *const Bundle, run: *const Run, host: Host) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const s = &b.scenario;
    const samples = run.info.samples;
    const ionosphere = run.ionosphere();
    const first_epoch = run.entryEpoch();
    var entries: [std.meta.tags(types.Signal).len]SignalEntry = undefined;
    var n: usize = 0;
    var it = run.generatedSignals().iterator();
    while (it.next()) |signal| {
        entries[n] = .{ .signal = signal.name(), .system = signal.system().name() };
        n += 1;
    }
    const navigation = try gpa.alloc([]const u8, s.nav_files.len);
    defer gpa.free(navigation);
    for (navigation, s.nav_files) |*path, f| path.* = f.path;
    var ionosphere_systems: [types.System.all.len]IonosphereSystemDocument = undefined;
    var system_parameters: [types.System.all.len][max_parameters]f64 = undefined;
    var system_count: usize = 0;
    var parameters: []const f64 = &.{};
    var systems = ionosphere.enabled.iterator();
    while (systems.next()) |system| {
        const model = ionosphere.models.get(system);
        const values = coefficients(model, &system_parameters[system_count]);
        ionosphere_systems[system_count] = .{
            .system = system.name(),
            .model = modelName(model),
            .parameters = values,
            .source = @tagName(ionosphere.sources.get(system)),
        };
        if (system_count == 0 and ionosphere.requested != .auto) parameters = values;
        system_count += 1;
    }
    const doc: Document = .{
        .antenna = s.antenna,
        .ionosphere = .{ .model = ionosphere.requested.name(), .parameters = parameters, .systems = ionosphere_systems[0..system_count] },
        .navigation = navigation,
        .output = .{
            .center_freq_mhz = samples.center.mhz(),
            .duration_ms = run.info.span.epochs - first_epoch.ms,
            .file = host.file,
            .first_epoch = first_epoch.ms,
            .format = samples.format.name(),
            .sample_freq_mhz = samples.sample_rate.mhz(),
            .size_bytes = run.total_bytes,
        },
        .precise = if (s.precise) |p| .{ .clock = p.clock, .orbit = p.orbit, .phase_centre = if (s.antenna != null) "antenna" else "centre_of_mass" } else null,
        .run_id = host.run_id,
        .scenario_name = s.name,
        .services = .{
            .has = if (s.has) |h| .{ .clock_interval_s = h.clock_interval_s, .orbit_interval_s = h.orbit_interval_s, .status = h.status.name() } else null,
            .ppp_b2b = if (s.ppp_b2b) |p| .{ .clock_interval_s = p.clock_interval_s, .orbit_interval_s = p.orbit_interval_s } else null,
        },
        .signals = entries[0..n],
        .start_time = host.start_time,
    };
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_4 }, w);
}

fn modelName(model: *const iono.Model) []const u8 {
    return switch (model.*) {
        inline else => |_, tag| @field(ModelKind, @tagName(tag)).name(),
    };
}

fn coefficients(model: *const iono.Model, buf: *[max_parameters]f64) []const f64 {
    return switch (model.*) {
        .none => &.{},
        .klobuchar => |k| klobuchar(k, buf),
        .bds_klobuchar => |b| klobuchar(b.coefficients, buf),
        .nequick => |q| blk: {
            buf[0..3].* = .{ q.coefficients.ai0, q.coefficients.ai1, q.coefficients.ai2 };
            break :blk buf[0..3];
        },
        .bdgim => |m| blk: {
            buf.* = m.alpha;
            break :blk buf;
        },
    };
}

fn klobuchar(k: iono.klobuchar.Model, buf: *[max_parameters]f64) []const f64 {
    buf[0..4].* = k.alpha;
    buf[4..8].* = k.beta;
    return buf[0..8];
}
