const std = @import("std");
const gnss_types = @import("domain/gnss_types");
const ionosphere_config = @import("simulation/model/ionosphere");
const Klobuchar = @import("domain/propagation/ionosphere/klobuchar").Model;
const NavFile = @import("phb/model/names").NavFile;
const ModelKind = ionosphere_config.Model;
const PreparedBundle = @import("phb/prepared").PreparedBundle;
const Run = @import("products/run/engine/run").Run;

pub const Metadata = struct { start_time_iso: []const u8, run_id: []const u8, output_path: []const u8 };

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
    navigation: NavPaths,
    output: struct { center_freq_mhz: f64, duration_ms: u64, file: []const u8, first_epoch: u64, format: []const u8, sample_freq_mhz: f64, size_bytes: u64 },
    precise: ?PreciseDocument,
    run_id: []const u8,
    scenario_name: []const u8,
    services: struct { has: ?HasDocument, ppp_b2b: ?PppB2bDocument },
    signals: []const SignalEntry,
    start_time: []const u8,
};

const NavPaths = struct {
    files: []const NavFile,

    pub fn jsonStringify(self: NavPaths, writer: anytype) !void {
        try writer.beginArray();
        for (self.files) |file| try writer.write(file.path);
        try writer.endArray();
    }
};

pub fn write(w: *std.Io.Writer, b: *const PreparedBundle, run: *const Run, metadata: Metadata) std.Io.Writer.Error!void {
    const names = b.display.names;
    const config = &b.scenario.config;
    const info = run.info();
    const status = run.status();
    const samples = info.samples;
    const ionosphere = run.ionosphere();
    const first_epoch = status.entry_epoch;
    var entries: [std.enums.values(gnss_types.Signal).len]SignalEntry = undefined;
    var n: usize = 0;
    var it = run.generatedSignals().iterator();
    while (it.next()) |signal| {
        entries[n] = .{ .signal = signal.name(), .system = signal.system().name() };
        n += 1;
    }
    var ionosphere_systems: [gnss_types.System.all.len]IonosphereSystemDocument = undefined;
    var system_parameters: [gnss_types.System.all.len][max_parameters]f64 = undefined;
    var system_count: usize = 0;
    var parameters: []const f64 = &.{};
    var systems = ionosphere.enabled.iterator();
    while (systems.next()) |system| {
        const applied = ionosphere.resolved.systems.get(system);
        const values = coefficients(applied.model, &ionosphere.resolved.broadcast, &system_parameters[system_count]);
        ionosphere_systems[system_count] = .{
            .system = system.name(),
            .model = applied.model.name(),
            .parameters = values,
            .source = @tagName(applied.source),
        };
        if (system_count == 0 and ionosphere.resolved.requested != .auto) parameters = values;
        system_count += 1;
    }
    const doc: Document = .{
        .antenna = names.antenna,
        .ionosphere = .{ .model = ionosphere.resolved.requested.name(), .parameters = parameters, .systems = ionosphere_systems[0..system_count] },
        .navigation = .{ .files = names.nav_files },
        .output = .{
            .center_freq_mhz = samples.center.mhz(),
            .duration_ms = info.span.epochs - first_epoch.ms,
            .file = metadata.output_path,
            .first_epoch = first_epoch.ms,
            .format = samples.format.name(),
            .sample_freq_mhz = samples.sample_rate.mhz(),
            .size_bytes = status.total_bytes,
        },
        .precise = if (names.precise) |p| .{ .clock = p.clock, .orbit = p.orbit, .phase_centre = if (names.antenna != null) "antenna" else "centre_of_mass" } else null,
        .run_id = metadata.run_id,
        .scenario_name = names.name,
        .services = .{
            .has = if (config.has) |h| .{ .clock_interval_s = h.clock_interval_s, .orbit_interval_s = h.orbit_interval_s, .status = h.status.name() } else null,
            .ppp_b2b = if (config.ppp_b2b) |p| .{ .clock_interval_s = p.clock_interval_s, .orbit_interval_s = p.orbit_interval_s } else null,
        },
        .signals = entries[0..n],
        .start_time = metadata.start_time_iso,
    };
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_4 }, w);
}

fn coefficients(model: ModelKind, broadcast: *const ionosphere_config.Broadcast, buf: *[max_parameters]f64) []const f64 {
    return switch (model) {
        .none => &.{},
        .klobuchar => klobuchar(broadcast.klobuchar, buf),
        .bds_klobuchar => klobuchar(broadcast.bds_klobuchar, buf),
        .nequick => blk: {
            const q = broadcast.nequick.?;
            buf[0..3].* = .{ q.ai0, q.ai1, q.ai2 };
            break :blk buf[0..3];
        },
        .bdgim => blk: {
            buf.* = broadcast.bdgim.?;
            break :blk buf;
        },
    };
}

fn klobuchar(k: Klobuchar, buf: *[max_parameters]f64) []const f64 {
    buf[0..4].* = k.alpha;
    buf[4..8].* = k.beta;
    return buf[0..8];
}
