const std = @import("std");
const diagnostics = @import("base/diagnostics");
const records = @import("domain/navigation/records");
const system_data = @import("domain/navigation/system_data");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const civil = @import("domain/time/civil");
const catalog = @import("domain/navigation/antenna/catalog");
const yaw_law = @import("domain/navigation/antenna/yaw_law");
const precise_product = @import("domain/navigation/precise/product");
const ionosphere_config = @import("simulation/model/ionosphere");
const names = @import("phb/model/names");
const request = @import("products/pack/input/scenario/request");
const navigation = @import("products/pack/input/admission/navigation");
const files = @import("products/pack/input/sources");
const rinex = @import("products/pack/input/formats/rinex/navigation/read");
const almanac = @import("products/pack/input/formats/almanac/read");
const sp3 = @import("products/pack/input/formats/sp3");
const clk = @import("products/pack/input/formats/rinex/clock");
const antex = @import("products/pack/input/formats/antex");
const Number = @import("base/text/number").Number;
const GpsTime = @import("domain/time/gps").GpsTime;
const Rejections = @import("products/pack/input/rejections").Rejections;
const Diagnostics = diagnostics.Diagnostics;

pub const Loaded = struct {
    ephemerides: records.Ephemerides,
    systems: system_data.SystemRecords,
    ionosphere: ionosphere_model.SuppliedCoefficients,
    almanacs: []const records.Almanac,
    leap: civil.Leap,
};

const LoadedFile = struct { spec: names.NavFile, bytes: []const u8, path: []const u8 };
const Identified = struct {
    file: LoadedFile,
    format: union(enum) { rinex: rinex.HeaderRead, almanac: almanac.Format },
};
const Declared = struct { declaration: system_data.LeapDeclaration, path: []const u8, name: []const u8 };

pub fn load(arena: std.mem.Allocator, source: files.Source, nav_files: []const names.NavFile, reference: GpsTime, diags: *Diagnostics) diagnostics.LoadError!Loaded {
    const loaded = try readFiles(arena, source, nav_files, diags);
    const identified = try identify(arena, loaded, diags);
    const declaration = declared(identified);
    const leap: civil.Leap = if (declaration) |value| system_data.leapSchedule(value.declaration, reference) catch |err| {
        try leapDiagnostic(diags, value, reference, err);
        return error.InvalidInput;
    } else .table;
    if (declaration) |value| if (leap.event == null and leap.count != leap.table_insertions) {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = value.name, .path = value.path };
        try scope.warn(.no_record, null, "declares {d} leap seconds where the built-in history ends at {d}, without the week and day of the change: the UTC parameters are not broadcast", .{ leap.count, leap.table_insertions });
    };
    return decode(arena, identified, reference, leap, declaration, diags);
}

pub fn antenna(arena: std.mem.Allocator, source: files.Source, path: []const u8, diags: *Diagnostics) diagnostics.LoadError![]const catalog.Antenna {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = "antenna" };
    const atx = try antex.parse(arena, text(try files.readResolved(arena, source, path, files.max_navigation_bytes, scope)), scope);
    if (atx.len == 0) try scope.warn(.no_record, null, "the file gives no satellite antenna", .{});
    try warnAttitude(atx, scope);
    return atx;
}

pub fn precise(arena: std.mem.Allocator, source: files.Source, p: request.Precise, leap: civil.Leap, diags: *Diagnostics) diagnostics.LoadError!precise_product.Data {
    var orbit: std.ArrayList(precise_product.OrbitSample) = .empty;
    const first_scope: diagnostics.Scope = .{ .diags = diags, .source = p.orbit[0], .path = "precise.orbit[0]" };
    const first = try sp3.parse(arena, text(try files.readResolved(arena, source, p.orbit[0], files.max_navigation_bytes, first_scope)), leap, first_scope);
    const interval_s = first.interval_s;
    var first_epoch: ?GpsTime = if (first.samples.len > 0) first.samples[0].t else null;
    try orbit.appendSlice(arena, first.samples);
    for (p.orbit[1..], 1..) |path, index| {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = try arena.print("precise.orbit[{d}]", .{index}) };
        const file = try sp3.parse(arena, text(try files.readResolved(arena, source, path, files.max_navigation_bytes, scope)), leap, scope);
        if (interval_s != file.interval_s) return scope.fail(.invalid_format, null, "the SP3 interval {f} s does not match the earlier files' {f} s", .{ Number{ .value = file.interval_s, .apart = interval_s }, Number{ .value = interval_s, .apart = file.interval_s } });
        if (file.samples.len > 0) {
            if (first_epoch) |t0| {
                if (!sp3.onGrid(file.samples[0].t, t0, interval_s)) return scope.fail(.invalid_format, null, "the first SP3 epoch does not lie on the earlier files' sampling grid", .{});
            } else first_epoch = file.samples[0].t;
        }
        try orbit.appendSlice(arena, file.samples);
    }
    var clocks: std.ArrayList(precise_product.ClockRecord) = .empty;
    for (p.clock, 0..) |path, index| {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = try arena.print("precise.clock[{d}]", .{index}) };
        try clocks.appendSlice(arena, try clk.parse(arena, text(try files.readResolved(arena, source, path, files.max_navigation_bytes, scope)), leap, scope));
    }
    const scope: diagnostics.Scope = .{ .diags = diags, .source = diags.source, .path = "precise" };
    const data = precise_product.Data.build(arena, orbit.items, interval_s, clocks.items, p.clock_reference) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EmptyProduct => "the precise product has no orbit samples",
            error.SparseEpochs => "the precise product's orbit samples are too sparse",
            error.MalformedRecord => "the precise product has an orbit sample outside its sampling grid",
        };
        return scope.fail(.invalid_format, null, "{s}", .{message});
    };
    return data;
}

fn readFiles(arena: std.mem.Allocator, source: files.Source, inputs: []const names.NavFile, diags: *Diagnostics) diagnostics.LoadError![]const LoadedFile {
    const result = try arena.alloc(LoadedFile, inputs.len);
    var ordinal = std.EnumArray(names.NavKind, usize).initFill(0);
    for (inputs, result) |input, *file| {
        const i = ordinal.get(input.kind);
        ordinal.set(input.kind, i + 1);
        const path = try arena.print("{s}[{d}].name", .{ names.NavKind.words.get(input.kind), i });
        const scope: diagnostics.Scope = .{ .diags = diags, .source = input.path, .path = path };
        file.* = .{ .spec = input, .bytes = text(try files.readResolved(arena, source, input.path, files.max_navigation_bytes, scope)), .path = path };
    }
    return result;
}

fn identify(arena: std.mem.Allocator, loaded: []const LoadedFile, diags: *Diagnostics) diagnostics.InputError![]const Identified {
    const result = try arena.alloc(Identified, loaded.len);
    for (loaded, result) |file, *identified| {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = file.spec.path, .path = file.path };
        const format = almanac.detect(file.bytes);
        identified.* = .{ .file = file, .format = switch (file.spec.kind) {
            .almanac => .{ .almanac = format orelse return scope.fail(.invalid_format, null, "expected an almanac file", .{}) },
            .ephemeris => blk: {
                if (format != null) return scope.fail(.invalid_format, null, "an almanac file must be listed under almanac, not ephemeris", .{});
                break :blk .{ .rinex = try rinex.readHeader(arena, file.bytes, scope) };
            },
        } };
    }
    return result;
}

fn declared(identified: []const Identified) ?Declared {
    for (identified) |input| switch (input.format) {
        .rinex => |header| if (header.metadata.leap) |value| return .{ .declaration = value, .path = input.file.path, .name = input.file.spec.path },
        .almanac => {},
    };
    return null;
}

fn decode(arena: std.mem.Allocator, identified: []const Identified, reference: GpsTime, leap: civil.Leap, first_declaration: ?Declared, diags: *Diagnostics) diagnostics.InputError!Loaded {
    var pools: rinex.Pools = .{ .arena = arena, .leap = leap };
    var almanacs: std.ArrayList(records.Almanac) = .empty;
    var coefficients: ionosphere_model.SuppliedCoefficients = .{};
    for (identified) |input| {
        const file = input.file;
        const scope: diagnostics.Scope = .{ .diags = diags, .source = file.spec.path, .path = file.path };
        switch (input.format) {
            .almanac => |format| {
                const parsed = try almanac.parse(arena, format, file.bytes, reference, leap, scope);
                const kept = try plausibleAlmanacs(arena, scope, parsed);
                if (kept.len == 0) try scope.warn(.no_record, null, "the file gives no almanac", .{});
                try almanacs.appendSlice(arena, kept);
            },
            .rinex => |header| {
                pools.issues = .{};
                try pools.time_offsets.appendSlice(arena, header.offsets);
                const before = pools.kepler.items.len + pools.glonass.items.len;
                try rinex.readBody(&pools, file.bytes, header);
                try pools.issues.report(scope);
                if (pools.kepler.items.len + pools.glonass.items.len == before) try scope.warn(.no_record, null, "the file gives no ephemeris record of GPS, Galileo, BDS or GLONASS", .{});
                inline for (@typeInfo(ionosphere_model.SuppliedCoefficients).@"struct".field_names) |name| {
                    if (@field(coefficients, name) == null) @field(coefficients, name) = try fitting(scope, name, @field(header.metadata.iono, name));
                }
                if (first_declaration) |first| if (header.metadata.leap) |other| if (!std.meta.eql(first.declaration, other)) {
                    try scope.warn(.implausible_record, null, "declares {d} leap seconds where an earlier file declares {d}: the run flies the first declaration", .{ other.delta_tls, first.declaration.delta_tls });
                };
            },
        }
    }
    return .{
        .ephemerides = .{ .kepler = pools.kepler.items, .glonass = pools.glonass.items },
        .systems = .{ .time_offsets = pools.time_offsets.items, .eops = pools.eops.items },
        .ionosphere = transmitted(pools.ions.items, reference, coefficients),
        .almanacs = almanacs.items,
        .leap = leap,
    };
}

fn leapDiagnostic(diags: *Diagnostics, declaration: Declared, start: GpsTime, err: system_data.LeapError) std.mem.Allocator.Error!void {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = declaration.name, .path = declaration.path };
    switch (err) {
        error.LeapCountNegative => try scope.err(.out_of_range, null, "declares {d} leap seconds, a count below zero", .{declaration.declaration.delta_tls}),
        error.LeapCountDisagrees => try scope.err(.out_of_range, null, "declares {d} leap seconds where {d} were in force at the run start, {f}: inside the built-in history the data cannot declare another count", .{ declaration.declaration.delta_tls, civil.Leap.insertionsAt(start.ms), start.printed(null) }),
    }
}

fn plausibleAlmanacs(arena: std.mem.Allocator, scope: diagnostics.Scope, list: []records.Almanac) std.mem.Allocator.Error![]const records.Almanac {
    var issues: Rejections = .{};
    var count: usize = 0;
    for (list) |record| {
        const unfit = switch (record) {
            .kepler => |*value| navigation.almanac(value),
            .glonass => |*value| navigation.glonassAlmanac(value),
        };
        const field = unfit orelse {
            list[count] = record;
            count += 1;
            continue;
        };
        const sat = record.sat();
        try issues.add(arena, .{ .system = sat.system, .message = "almanac", .field = field, .named = switch (record) {
            .kepler => |value| .{ .record = .{ .prn = sat.prn(), .epoch = value.toa.toCalendar() } },
            .glonass => |value| .{ .label = try arena.print("{f} N4 {d} NA {d}", .{ sat, value.n4, value.na }) },
        } });
    }
    try issues.report(scope);
    return list[0..count];
}

fn fitting(scope: diagnostics.Scope, comptime name: []const u8, set: anytype) std.mem.Allocator.Error!@TypeOf(set) {
    const value = set orelse return null;
    var supplied: ionosphere_model.SuppliedCoefficients = .{};
    @field(supplied, name) = value;
    if (navigation.broadcastIono(supplied)) |field| {
        try scope.warn(.implausible_record, null, "the {s} set of the header is dropped, {s} outside its broadcast field", .{ ionosphere_config.Model.words.get(@field(ionosphere_config.Model, name)), field });
        return null;
    }
    return value;
}

fn transmitted(ions: []const rinex.Ion, start: GpsTime, fallback: ionosphere_model.SuppliedCoefficients) ionosphere_model.SuppliedCoefficients {
    var result = fallback;
    inline for (@typeInfo(ionosphere_model.SuppliedCoefficients).@"struct".field_names) |name| {
        var best: ?rinex.Ion = null;
        for (ions) |ion| {
            if (@field(ion.set, name) == null or start.lessThan(ion.transmitted)) continue;
            if (best) |value| if (!value.transmitted.lessThan(ion.transmitted)) continue;
            best = ion;
        }
        if (best) |value| @field(result, name) = @field(value.set, name);
    }
    return result;
}

fn warnAttitude(atx: []const catalog.Antenna, scope: diagnostics.Scope) std.mem.Allocator.Error!void {
    for (atx, 0..) |a, i| {
        if (yaw_law.lawOf(a.kind) != .nominal) continue;
        var seen = false;
        for (atx[0..i]) |b| seen = seen or std.mem.eql(u8, a.kind, b.kind);
        if (seen) continue;
        try scope.warn(.no_record, null, "no yaw law is held for the antenna type {f}: its satellites fly the nominal law through their turns", .{diagnostics.Escaped{ .text = a.kind }});
    }
}

fn text(bytes: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;
}
