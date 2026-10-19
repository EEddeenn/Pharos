const std = @import("std");
const bundle = @import("shared").bundle;
const gnss = @import("shared").gnss;
const galileo = gnss.galileo;
const stage = @import("shared").stage;
const messages = stage.messages;
const NavFamily = @import("shared").core.types.NavFamily;
const GpsTime = @import("shared").core.time.GpsTime;
const Leap = @import("shared").core.civil.Leap;
const trajectory = @import("shared").trajectory;
const node = @import("shared").json.node;
const scenario = @import("scenario.zig");
const diagnostics = @import("shared").core.diagnostics;
const Diagnostics = diagnostics.Diagnostics;
const nav = @import("nav.zig");
const plan = @import("plan.zig");
const NavSet = bundle.navigation.NavSet;

pub const Error = diagnostics.LoadError;

pub const Assembled = struct { bundle: bundle.Bundle, span: bundle.Span, skipped: u32 };

pub fn assemble(arena: std.mem.Allocator, source: nav.files.Source, text: []const u8, diags: *Diagnostics) Error!Assembled {
    const request = try scenario.read.parse(arena, text, diags);
    try scenario.validate.validate(&request, diags);
    if (diags.hasErrors()) return error.InvalidInput;

    const traj = try loadTrajectory(arena, source, request.trajectory_file, diags);
    if (request.duration_ms) |duration| if (duration > traj.epochs()) {
        const lasts: node.Number = .{ .value = traj.duration(), .outside = .{ .min = @as(f64, @floatFromInt(duration)) / 1000 } };
        try diags.err(.out_of_range, "duration", "the trajectory lasts {f} s", .{lasts});
        return error.InvalidInput;
    };
    if (traj.epochs() == 0) {
        try diags.err(.out_of_range, "trajectory", "the trajectory lasts {f} s, less than an epoch of 1 ms", .{node.Number{ .value = traj.duration(), .outside = .{ .min = 1e-3 } }});
        return error.InvalidInput;
    }

    const loaded = try nav.load.load(arena, source, request.nav_files, request.start, diags);
    var set = loaded.set;
    const s = scenario.resolve(&request, loaded.header.iono, traj.epochs()) catch |e| {
        switch (e) {
            error.MissingIonoParameters => try diags.err(.missing_field, "ionosphere.parameters", "the {s} model has no coefficients: none here and no set of it transmitted in the navigation data by the run start", .{request.ionosphere.model().name()}),
            error.MissingGalileoIonoParameters => try diags.err(.missing_field, "ionosphere.model", "auto selected nequick for Galileo, but the navigation data have no coefficients transmitted by the run start", .{}),
            error.MissingBdsIonoParameters => try diags.err(.missing_field, "ionosphere.model", "auto requires BDGIM or BDS Klobuchar coefficients for BDS, but the navigation data have neither set transmitted by the run start", .{}),
        }
        return error.InvalidInput;
    };
    const run_ms = s.duration_ms;
    if (!utcServed(&s, &set, loaded.leap)) {
        try diags.err(.missing_field, "ephemeris", "an E5a signal is listed but the navigation data transmit no GST-UTC usable at the run start: F/NAV page 4 would be a dummy page for the whole run, carrying neither Cic and Cis nor the GGTO", .{});
        return error.InvalidInput;
    }

    if (s.antenna) |path| {
        set.antenna = try nav.load.antenna(arena, source, path, diags);
    }
    var product: ?*bundle.precise.Product = null;
    if (s.precise) |p| {
        const loaded_product = try nav.load.precise(arena, source, p, loaded.leap, diags);
        product = loaded_product;
        set.precise = loaded_product;
    }

    var flight = plan.build(arena, &s, &set, loaded.almanacs, run_ms, loaded.leap) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LegBoundaryStalls => return stalledPlan(diags),
    };
    try plan.warnClockReference(&set, &flight, diags);
    try plan.warnUnserved(&set, &flight, diags);
    try plan.reportCoverage(&flight, &s, run_ms, diags);
    plan.setGlonassFrequencies(&set);
    try plan.trim(arena, &set, &flight, product);
    try plan.d1d2.prepare(arena, &s, &set, &flight);
    try plan.warnUnfit(&s, &set, &flight, diags);

    const b: bundle.Bundle = .{ .scenario = s, .navigation = set, .plan = flight, .trajectory = traj };
    try checkMessages(arena, &b, run_ms, diags);
    return .{ .bundle = b, .span = b.span(), .skipped = loaded.skipped };
}

pub fn describe(arena: std.mem.Allocator, file: nav.files.File, diags: *Diagnostics) Error![]const plan.Covered {
    const reference: GpsTime = .{ .ms = Leap.table.lastInsertion().?.at_ms };
    const loaded = try nav.load.load(arena, .{ .memory = &.{file} }, &.{.{ .path = file.name, .kind = .ephemeris }}, reference, diags);
    return plan.coverage(arena, &loaded.set, loaded.leap) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LegBoundaryStalls => return stalledPlan(diags),
    };
}

fn checkMessages(arena: std.mem.Allocator, b: *const bundle.Bundle, run_ms: u64, diags: *Diagnostics) Error!void {
    const s = &b.scenario;
    if (s.samples == null) return;
    const families = messages.familiesOf(s.signals);
    const allocation = gnss.allocation.at(s.start);
    const broadcast = s.ionosphere.ready.broadcast;
    var failure: messages.PreparationFailure = undefined;
    const prepared = messages.Messages.prepare(arena, s.messages, families, s.start, &failure) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPublication => return publicationFailure(arena, failure, diags),
    };
    const end = s.start.addMs(@intCast(run_ms));
    inline for (comptime std.enums.values(NavFamily)) |family| {
        if (families.contains(family)) {
            const storage = try arena.create(messages.Set(family));
            var t = s.start;
            while (t.lessThan(end)) {
                messages.build(family, storage, b, &allocation, &broadcast, prepared, .{}, t) catch |e| {
                    try diags.err(.out_of_range, "ephemeris", "{s} at {d} s into the run: the navigation data cannot be encoded into its message set ({s})", .{ family.name(), into(s, t), encoding(e) });
                    return error.InvalidInput;
                };
                var snapshot: messages.Snapshot = .{};
                @field(snapshot, @tagName(family)) = storage;
                try requireData(family, snapshot, s, &allocation, t, diags);
                t = bundle.plan.nextLegBoundary(family.system(), t, b.plan.leap);
            }
        }
    }
}

/// The seconds from the run start: whole milliseconds, so written with every digit.
fn into(s: *const bundle.scenario.Scenario, t: GpsTime) f64 {
    return @as(f64, @floatFromInt(t.ms - s.start.ms)) / 1000;
}

fn requireData(family: NavFamily, snapshot: messages.Snapshot, s: *const bundle.scenario.Scenario, allocation: *const gnss.allocation.Allocation, t: GpsTime, diags: *Diagnostics) Error!void {
    var it = s.signals.iterator();
    while (it.next()) |signal| {
        if (gnss.spec.get(signal).family != family) continue;
        const set = messages.forSignal(snapshot, signal).?;
        var sats = signal.system().satellites();
        while (sats.next()) |sat| {
            if (!allocation.transmits(sat, signal)) continue;
            set.requireData(sat.prn()) catch |e| {
                try diags.err(.missing_field, "ephemeris", "{s} at {d} s into the run: {s}", .{ family.name(), into(s, t), messages.reason(e) });
                return error.InvalidInput;
            };
        }
    }
}

fn publicationFailure(arena: std.mem.Allocator, failure: messages.PreparationFailure, diags: *Diagnostics) Error!void {
    const target: struct { key: []const u8, family: []const u8 } = switch (failure.target) {
        .gps => .{ .key = "messages.gps", .family = "LNAV and CNAV" },
        .cnav2 => .{ .key = "messages.gps", .family = "CNAV-2" },
        .inav => .{ .key = "messages.galileo.inav", .family = "I/NAV" },
        .d2 => .{ .key = "messages.bds.d2", .family = "D2" },
    };
    const path = try arena.print("{s}[{d}]", .{ target.key, failure.publication.index });
    try diags.err(.out_of_range, path, "the publication cannot be encoded for {s} ({s})", .{ target.family, encoding(failure.publication.reason) });
    return error.InvalidInput;
}

fn encoding(e: gnss.publication.EncodingError) []const u8 {
    return switch (e) {
        error.ValueOutOfRange => "a value lies outside its range",
        error.FieldOverflow => "a value does not fit its field",
        error.ValueMissing => "a value is missing",
    };
}

fn utcServed(s: *const bundle.scenario.Scenario, set: *const NavSet, leap: Leap) bool {
    if (s.samples == null) return true;
    if (!s.carries(.fnav)) return true;
    return galileo.time_parameters.utcBlock(set.utc(.gal, s.start, leap), s.start) != null;
}

fn loadTrajectory(arena: std.mem.Allocator, source: nav.files.Source, path: []const u8, diags: *Diagnostics) Error!trajectory.Trajectory {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = "trajectory" };
    const bytes = try nav.files.readResolved(arena, source, path, trajectory.pht.max_bytes, scope);
    return trajectory.pht.read(arena, bytes, scope);
}

fn stalledPlan(diags: *Diagnostics) diagnostics.InputError {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = diags.source, .path = "ephemeris" };
    return scope.fail(.out_of_range, null, "the navigation selection schedule does not advance past a leg boundary", .{});
}
