const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const spec = gnss.spec;
const model = @import("shared").bundle.scenario;
const Request = @import("request.zig").Request;
const Diagnostics = @import("shared").core.diagnostics.Diagnostics;

const usual_noise_floor_dbm_hz = [2]f64{ -200, -100 };

const Error = std.mem.Allocator.Error;

pub fn validate(s: *const Request, diags: *Diagnostics) Error!void {
    try validateTrajectory(s, diags);
    try validateNavFiles(s, diags);
    try validatePrecise(s, diags);
    try validateOutputs(s, diags);
    try validatePower(s, diags);
    try validateEffect(s, diags);
}

fn validateTrajectory(s: *const Request, diags: *Diagnostics) Error!void {
    if (s.trajectory_file.len == 0) try diags.err(.missing_field, "trajectory", "must be non-empty", .{});
}

fn validateNavFiles(s: *const Request, diags: *Diagnostics) Error!void {
    if (s.nav_files.len == 0 and (s.samples != null or s.observation != null)) {
        try diags.err(.missing_field, "ephemeris", "the samples and the observation file need at least one navigation file", .{});
    }
    var index = std.EnumArray(model.NavKind, usize).initFill(0);
    for (s.nav_files) |f| {
        const i = index.get(f.kind);
        index.set(f.kind, i + 1);
        if (f.path.len == 0) {
            const path = try std.fmt.allocPrint(diags.arena, "{s}[{d}].name", .{ model.NavKind.words.get(f.kind), i });
            try diags.err(.missing_field, path, "must be non-empty", .{});
        }
    }
    if (s.antenna) |a| if (a.len == 0) {
        try diags.err(.missing_field, "antenna", "must be non-empty", .{});
    };
}

fn validatePrecise(s: *const Request, diags: *Diagnostics) Error!void {
    const p = s.precise orelse return;
    for (p.orbit, 0..) |path, i| if (path.len == 0) {
        try diags.err(.missing_field, try std.fmt.allocPrint(diags.arena, "precise.orbit[{d}]", .{i}), "must be non-empty", .{});
    };
    for (p.clock, 0..) |path, i| if (path.len == 0) {
        try diags.err(.missing_field, try std.fmt.allocPrint(diags.arena, "precise.clock[{d}]", .{i}), "must be non-empty", .{});
    };
}

fn validateOutputs(s: *const Request, diags: *Diagnostics) Error!void {
    if (s.samples == null and s.observation == null and s.position == null) {
        try diags.err(.no_output, "", "no samples, observation or position block", .{});
    }
    if (s.samples) |x| {
        if (x.format == .iq2 and x.sample_rate.samplesPerEpoch() % 2 != 0) {
            try diags.err(.odd_sample_count, "samples.sampleFreq", "IQ2 packs two samples per byte; {d} samples per millisecond is odd", .{x.sample_rate.samplesPerEpoch()});
        }
        if (s.signals.count() == 0) try diags.err(.no_signal, "signals", "no signal is listed", .{});
        var it = s.signals.iterator();
        while (it.next()) |signal| try validateBand(x, signal, diags);
    }
    if (s.observation != null and s.samples == null and s.signals.count() == 0) try diags.err(.no_signal, "signals", "no signal is listed", .{});
}

fn validateBand(x: model.Samples, signal: core.types.Signal, diags: *Diagnostics) Error!void {
    const row = spec.get(signal);
    if (row.carrier == .fixed) {
        const carrier = row.carrierHz(null);
        if (!x.inBand(carrier)) try diags.warn(.band_excluded, "signals", "{s} at {d} MHz lies outside the sampled band and will not be generated", .{ signal.name(), mhz(carrier) });
        return;
    }
    const plan = gnss.glonass.signals;
    var inside: ?[2]i32 = null;
    var k: i5 = plan.plan_k_min;
    while (k <= plan.plan_k_max) : (k += 1) {
        if (!x.inBand(row.carrierHz(.{ .k = k }))) continue;
        if (inside) |*run| run[1] = k else inside = .{ k, k };
    }
    const run = inside orelse {
        const low = row.carrierHz(.{ .k = plan.plan_k_min });
        const high = row.carrierHz(.{ .k = plan.plan_k_max });
        try diags.warn(.band_excluded, "signals", "{s} at {d}-{d} MHz (k {d}..{d}) lies outside the sampled band and will not be generated", .{ signal.name(), mhz(low), mhz(high), plan.plan_k_min, plan.plan_k_max });
        return;
    };
    if (run[0] == plan.plan_k_min and run[1] == plan.plan_k_max) return;
    var outside: std.ArrayList(u8) = .empty;
    if (run[0] > plan.plan_k_min) try printRun(diags.arena, &outside, plan.plan_k_min, run[0] - 1);
    if (run[1] < plan.plan_k_max) {
        if (outside.items.len > 0) try outside.appendSlice(diags.arena, " and ");
        try printRun(diags.arena, &outside, run[1] + 1, plan.plan_k_max);
    }
    var kept: std.ArrayList(u8) = .empty;
    try printRun(diags.arena, &kept, run[0], run[1]);
    try diags.warn(.band_excluded, "signals", "{s} channels k {s} lie outside the sampled band and will not be generated (k {s} inside)", .{ signal.name(), outside.items, kept.items });
}

fn printRun(arena: std.mem.Allocator, out: *std.ArrayList(u8), a: i32, b: i32) Error!void {
    if (a == b) try out.print(arena, "{d}", .{a}) else try out.print(arena, "{d}..{d}", .{ a, b });
}

fn mhz(hz: u64) f64 {
    return @as(f64, @floatFromInt(hz)) / 1e6;
}

fn validatePower(s: *const Request, diags: *Diagnostics) Error!void {
    const p = &s.power;
    if (!(p.noise_floor_dbm_hz >= usual_noise_floor_dbm_hz[0] and p.noise_floor_dbm_hz <= usual_noise_floor_dbm_hz[1])) {
        try diags.warn(.out_of_range, "power.noiseFloor", "noise floor {d} dBm/Hz is outside the usual [-200, -100]", .{p.noise_floor_dbm_hz});
    }
    if (!(p.init_cn0_dbhz >= 0 and p.init_cn0_dbhz <= 60)) {
        try diags.warn(.out_of_range, "power.initPower", "initial C/N0 {d} dB-Hz is outside the usual [0, 60]", .{p.init_cn0_dbhz});
    }
}

fn validateEffect(s: *const Request, diags: *Diagnostics) Error!void {
    var listed = s.signals.iterator();
    while (listed.next()) |signal| {
        if (!transmitted(signal, s.start)) try diags.warn(.no_effect, "signals", "{s} is transmitted by no satellite at the start", .{signal.name()});
    }
    for (core.types.System.all) |system| {
        const first = gnss.allocation.start(system) orelse continue;
        if (!s.start.lessThan(first) or !listsSystem(s, system)) continue;
        const u = first.toUtc(.table);
        try diags.warn(.out_of_range, "time", "the {s} satellite allocation starts on {d}-{d:0>2}-{d:0>2}; an earlier start takes its first state", .{ system.displayName(), u.year, u.month, u.day });
    }
    try gpsMessagesEffect(s, diags);
    if (s.has != null) try serviceEffect(s, diags, "has", "HAS MT1", .e6);
    if (s.ppp_b2b != null) {
        try serviceEffect(s, diags, "pppB2b", "PPP-B2b", .b2b);
        if (s.samples != null and s.signals.contains(.b2b) and pppCarriersMasked(s)) {
            try diags.warn(.no_effect, "pppB2b", "PPP-B2b is carried by the BDS-3 GEO satellites, which are all masked out", .{});
        }
    }
    if (s.messages.d2.len > 0) try d2Effect(s, diags);
    for (core.types.System.all) |system| {
        if (listsSystem(s, system)) {
            if (allMasked(s, system)) {
                try diags.warn(.no_effect, "maskOut", "every {s} satellite transmitting a listed signal at the start is masked out; the run has no {s} channel", .{ system.displayName(), system.displayName() });
            }
            continue;
        }
        if (s.mask_out.get(system).count() > 0) {
            try diags.warn(.no_effect, "maskOut", "{s} satellites are masked out but no {s} signal is listed", .{ system.displayName(), system.displayName() });
        }
        for (s.power.schedule) |e| if (e.target.system() == system) {
            try diags.warn(.no_effect, "power.signalPower", "an entry sets {s} power but no {s} signal is listed", .{ system.displayName(), system.displayName() });
            break;
        };
    }
}

fn gpsMessagesEffect(s: *const Request, diags: *Diagnostics) Error!void {
    const list = s.messages.gps;
    if (list.len == 0) return;
    if (s.samples == null) {
        try diags.warn(.no_effect, "messages.gps", "GPS messages are transmitted in the samples and there is no samples block", .{});
        return;
    }
    var integrity = false;
    var text = false;
    var configuration = false;
    var ism = false;
    var differential = false;
    for (list) |p| {
        integrity = integrity or p.content.integrity != null;
        text = text or p.content.text != null;
        configuration = configuration or p.content.configuration != null;
        ism = ism or p.content.ism != null;
        differential = differential or p.content.differential != null;
    }
    const lnav = s.carries(.lnav);
    const cnav = s.carries(.cnav);
    const cnav2 = s.carries(.cnav2);
    if (integrity and !(lnav or cnav or cnav2)) try diags.warn(.no_effect, "messages.gps", "the integrity declaration is carried by L1CA, L2C, L5 and L1C, none of which is listed", .{});
    if (text and !(lnav or cnav or cnav2)) try diags.warn(.no_effect, "messages.gps", "the text is carried by L1CA, L2C, L5 and L1C, none of which is listed", .{});
    if (configuration and !(lnav or cnav2)) try diags.warn(.no_effect, "messages.gps", "the configuration codes are carried by L1CA and L1C, neither of which is listed", .{});
    if (ism and !(cnav or cnav2)) try diags.warn(.no_effect, "messages.gps", "the ISM is carried by L2C, L5 and L1C, none of which is listed", .{});
    if (differential) {
        if (!(cnav or cnav2)) {
            try diags.warn(.no_effect, "messages.gps", "the differential corrections are carried by L2C, L5 and L1C, none of which is listed", .{});
        } else if (s.precise == null) {
            try diags.warn(.no_effect, "messages.gps", "the signals fly with the broadcast records, so there is no differential correction to broadcast", .{});
        }
    }
}

fn serviceEffect(s: *const Request, diags: *Diagnostics, path: []const u8, service: []const u8, signal: core.types.Signal) Error!void {
    if (s.samples == null) {
        try diags.warn(.no_effect, path, "{s} is transmitted in the samples and there is no samples block", .{service});
    } else if (!s.signals.contains(signal)) {
        try diags.warn(.no_effect, path, "{s} is carried on {s}, which is not listed", .{ service, signal.name() });
    }
}

fn transmitted(signal: core.types.Signal, start: core.time.GpsTime) bool {
    var sats = signal.system().satellites();
    while (sats.next()) |sat| if (gnss.allocation.transmits(sat, signal, start)) return true;
    return false;
}

fn allMasked(s: *const Request, system: core.types.System) bool {
    const masked = s.mask_out.get(system);
    var sats = system.satellites();
    var transmitting = false;
    while (sats.next()) |sat| {
        if (s.transmitsListed(sat)) return false;
        if (masked.contains(sat) and s.listedSignalOf(sat) != null) transmitting = true;
    }
    return transmitting;
}

fn pppCarriersMasked(s: *const Request) bool {
    const masked = s.mask_out.get(.bds);
    var sats = core.types.System.bds.satellites();
    while (sats.next()) |sat| {
        if (gnss.bds.allocation.carriesPppB2b(sat.prn()) and gnss.allocation.transmits(sat, .b2b, s.start) and !masked.contains(sat)) return false;
    }
    return true;
}

fn d2Effect(s: *const Request, diags: *Diagnostics) Error!void {
    const listed = s.signals.contains(.b1i) or s.signals.contains(.b2i) or s.signals.contains(.b3i);
    if (s.samples == null or !listed) {
        try diags.warn(.no_effect, "messages.bds.d2", "the D2 augmentation is transmitted by the GEO satellites' B1I, B2I and B3I in the samples", .{});
        return;
    }
    const masked = s.mask_out.get(.bds);
    var sats = core.types.System.bds.satellites();
    const carried = while (sats.next()) |sat| {
        if (sendsD2(s, sat) and !masked.contains(sat)) break true;
    } else false;
    if (!carried) try diags.warn(.no_effect, "messages.bds.d2", "no GEO satellite outside maskOut transmits a listed B1I, B2I or B3I at the start (the BDS allocation) to carry the D2 augmentation", .{});
    if (!s.signals.contains(.b2i)) return;
    const integrity = gnss.bds.d1d2.integrity;
    for (s.messages.d2, 0..) |publication, i| if (publication.content.integrity) |declared| {
        var low: usize = 0;
        var high = false;
        for (declared.sv, 1..) |entry, id| if (entry != null) {
            if (id > integrity.basic_ids) high = true else low += 1;
        };
        if (high or low > integrity.basic_packets) {
            const path = try std.fmt.allocPrint(diags.arena, "messages.bds.d2[{d}].integrity.satellites", .{i});
            try diags.warn(.no_effect, path, "B2I describes satellites 1-30 only, at most 18 (BDS-SIS-ICD 2.1 5.3.3.5); the others are described on B1I and B3I only", .{});
        }
    };
}

fn sendsD2(s: *const Request, sat: core.types.SatId) bool {
    if (!gnss.bds.records.isGeo(sat.prn())) return false;
    for ([_]core.types.Signal{ .b1i, .b2i, .b3i }) |signal| {
        if (s.signals.contains(signal) and gnss.allocation.transmits(sat, signal, s.start)) return true;
    }
    return false;
}

fn listsSystem(s: *const Request, system: core.types.System) bool {
    var it = s.signals.iterator();
    while (it.next()) |signal| if (signal.system() == system) return true;
    return false;
}
