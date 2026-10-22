const std = @import("std");
const diagnostics = @import("base/diagnostics");
const civil = @import("domain/time/civil");
const gnss_types = @import("domain/gnss_types");
const trajectory = @import("domain/trajectory/trajectory");
const pht = @import("pht/read");
const precise = @import("domain/navigation/precise/product");
const signal_payload = @import("domain/signals/payload");
const model_file = @import("phb/model/file");
const derive = @import("phb/derive");
const selection = @import("simulation/model/signals");
const publications = @import("simulation/model/publications");
const prepared_messages = @import("simulation/model/prepared_messages");
const stored_systems = @import("simulation/model/systems");
const policy = @import("simulation/model/message_policy");
const flight_plan = @import("simulation/model/flight_plan");
const scenario = @import("products/pack/input/scenario/resolve");
const navigation = @import("products/pack/input/navigation/load");
const sources = @import("products/pack/input/sources");
const plan = @import("products/pack/planning/plan");
const almanacs = @import("products/pack/planning/almanacs");
const systems = @import("products/pack/planning/systems");
const compact = @import("products/pack/planning/compact");
const coverage = @import("products/pack/planning/coverage");
const reports = @import("products/pack/planning/reports");
const Number = @import("base/text/number").Number;
const GpsTime = @import("domain/time/gps").GpsTime;
const ClockReferences = @import("domain/navigation/clock_reference").ClockReferences;
const PreparedBundle = @import("phb/prepared").PreparedBundle;
const Config = @import("simulation/model/config").Config;
const ServicePlan = @import("simulation/model/services").ServicePlan;
const Request = @import("products/pack/input/scenario/request").Request;

pub const Error = diagnostics.LoadError;
pub const Assembled = struct { file: model_file.File, bundle: PreparedBundle };

/// Consumes a request accepted by readRequest. All output storage belongs to arena.
pub fn assemble(arena: std.mem.Allocator, source: sources.Source, request: *const Request, diags: *diagnostics.Diagnostics) Error!Assembled {
    try sources.admit(source, .{ .diags = diags, .source = diags.source, .path = "files" });
    const traj = try loadTrajectory(arena, source, request.trajectory_file, diags);
    if (request.duration_ms) |duration| if (duration > traj.epochs()) {
        const lasts: Number = .{ .value = traj.duration(), .outside = .{ .min = @as(f64, @floatFromInt(duration)) / 1000 } };
        try diags.err(.out_of_range, "duration", "the trajectory lasts {f} s", .{lasts});
        return error.InvalidInput;
    };
    if (traj.epochs() == 0) {
        try diags.err(.out_of_range, "trajectory", "the trajectory lasts {f} s, less than an epoch of 1 ms", .{Number{ .value = traj.duration(), .outside = .{ .min = 1e-3 } }});
        return error.InvalidInput;
    }
    const loaded = try navigation.load(arena, source, request.nav_files, request.start, diags);
    const config = scenario.resolve(request, loaded.ionosphere, traj.epochs(), diags) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingIonoParameters => try diags.err(.missing_field, "ionosphere.parameters", "the {s} model has no coefficients: none here and no set of it transmitted in the navigation data by the run start", .{request.ionosphere.model().name()}),
            error.MissingGalileoIonoParameters => try diags.err(.missing_field, "ionosphere.model", "auto selected nequick for Galileo, but the navigation data have no coefficients transmitted by the run start", .{}),
            error.MissingBdsIonoParameters => try diags.err(.missing_field, "ionosphere.model", "auto requires BDGIM or BDS Klobuchar coefficients for BDS, but the navigation data have neither set transmitted by the run start", .{}),
        }
        return error.InvalidInput;
    };
    const antennas = if (request.antenna) |path| try navigation.antenna(arena, source, path, diags) else &.{};
    const precise_data: ?precise.Data = if (request.precise) |value| try navigation.precise(arena, source, value, loaded.leap, diags) else null;
    const payload = signal_payload.at(config.start);
    const services = ServicePlan.init(&config, &request.messages, &payload, precise_data != null);
    const spans_ms = flight_plan.spansMs(config.signals, services, config.duration_ms);
    try admitFrontier(&config, spans_ms, loaded.leap, diags);
    const planned = try plan.build(arena, &config, &loaded.ephemerides, services, loaded.leap);
    const scales = systems.startScales(&loaded.systems, config.signals, config.start);
    var system_choices: stored_systems.Stored = .{ .records = loaded.systems, .scales = scales };
    var stored_almanacs: ?prepared_messages.StoredAlmanacs = null;
    var messages: ?prepared_messages.PreparedMessages = null;
    if (config.samples != null) {
        const families = policy.needed(config.signals, services, &payload);
        const declarations = try publications.Prepared.init(arena, request.messages, families, config.start);
        const almanac_plan = try almanacs.prepare(arena, loaded.ephemerides, loaded.almanacs, config.signals, families, config.start, loaded.leap, &declarations.configuration);
        const system_plan = try systems.prepare(arena, &config, loaded.systems, scales, spans_ms, almanac_plan.stored.glonass_day, loaded.leap, diags);
        stored_almanacs = almanac_plan.stored;
        system_choices = system_plan.stored;
        messages = .{ .publications = declarations, .almanacs = almanac_plan.prepared, .systems = system_plan.prepared };
    }
    const trimmed = try compact.compact(arena, loaded.ephemerides, planned.choices);
    const file: model_file.File = .{
        .config = config,
        .knots = traj.knots,
        .ephemerides = trimmed.ephemerides,
        .antennas = antennas,
        .precise = if (precise_data) |value| try compact.trimPrecise(arena, value, config.start, spans_ms) else null,
        .leap = loaded.leap,
        .plan = trimmed.choices,
        .almanacs = stored_almanacs,
        .systems = system_choices,
        .publications = request.messages,
        .names = .{
            .name = request.name,
            .trajectory_file = request.trajectory_file,
            .trajectory_name = traj.name,
            .nav_files = request.nav_files,
            .antenna = request.antenna,
            .precise = if (request.precise) |value| .{ .orbit = value.orbit, .clock = value.clock } else null,
        },
    };
    const prepared = try derive.build(arena, &file, planned.contents, messages);
    if (prepared.messages) |*value| try systems.requireData(&config, &prepared.flight_plan, &value.systems, &file.systems, diags);
    const clock_refs: ClockReferences = if (file.precise) |value| value.clock_reference else .{};
    try reports.warnAssumed(&config, &prepared.flight_plan, prepared.precise, clock_refs, diags);
    try reports.warnUnserved(prepared.precise, &prepared.flight_plan, diags);
    try reports.reportCoverage(&prepared.flight_plan, &config, diags);
    try reports.warnUnfit(&config, file.ephemerides, &prepared.flight_plan, diags);
    return .{ .file = file, .bundle = .{ .scenario = prepared, .display = .fromFile(&file) } };
}

pub fn describe(arena: std.mem.Allocator, file: sources.File, diags: *diagnostics.Diagnostics) Error![]const coverage.Covered {
    const reference: GpsTime = .{ .ms = civil.Leap.table.lastInsertion().?.at_ms };
    const loaded = try navigation.load(arena, .{ .memory = &.{file} }, &.{.{ .path = file.name, .kind = .ephemeris }}, reference, diags);
    return coverage.coverage(arena, &loaded.ephemerides, loaded.leap);
}

fn admitFrontier(config: *const Config, spans_ms: std.EnumArray(gnss_types.System, u64), leap: civil.Leap, diags: *diagnostics.Diagnostics) diagnostics.InputError!void {
    const frontier = config.start.addMs(@intCast(@max(config.duration_ms, std.mem.max(u64, &spans_ms.values))));
    if (frontier.toUtc(leap).year > 2099) {
        try diags.err(.out_of_range, "duration", "the run and its required planning interval must end before 2100", .{});
        return error.InvalidInput;
    }
    if (selection.systems(config.signals).contains(.glo)) {
        const until = config.start.addMs(@intCast(spans_ms.get(.glo)));
        if (civil.calendar(civil.moscowMs(leap, until.ms), until.sub_ms).year > 2099) {
            try diags.err(.out_of_range, "duration", "the GLONASS planning interval must end before 2100 in Moscow time", .{});
            return error.InvalidInput;
        }
    }
}

fn loadTrajectory(arena: std.mem.Allocator, source: sources.Source, path: []const u8, diags: *diagnostics.Diagnostics) Error!trajectory.Trajectory {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = "trajectory" };
    const bytes = try sources.readResolved(arena, source, path, sources.max_cache_bytes, scope);
    return pht.read(arena, bytes, scope);
}
