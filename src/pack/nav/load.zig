const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const bundle = @import("shared").bundle;
const diagnostics = core.diagnostics;
const Diagnostics = diagnostics.Diagnostics;
const GpsTime = core.time.GpsTime;
const records = gnss.records;
const NavSet = bundle.navigation.NavSet;
const Product = bundle.precise.Product;
const rinex = @import("rinex.zig");
const almanac = @import("almanac.zig");
const files = @import("files.zig");
const sp3 = @import("sp3.zig");
const clk = @import("clk.zig");
const antex = @import("antex.zig");

pub const Loaded = struct {
    set: NavSet,
    header: rinex.Header,
    almanacs: []const records.Almanac,
    leap: core.civil.Leap,
    skipped: u32,
};

const Declared = struct { declaration: gnss.auxiliary.LeapDeclaration, path: []const u8, name: []const u8 };

pub fn load(arena: std.mem.Allocator, source: files.Source, nav_files: []const bundle.scenario.NavFile, reference: GpsTime, diags: *Diagnostics) diagnostics.LoadError!Loaded {
    const texts = try arena.alloc([]const u8, nav_files.len);
    for (nav_files, texts) |file, *text| {
        text.* = try files.readResolved(arena, source, file.path, files.max_bytes, diags.forSource(file.path));
    }

    const declaration = try declared(arena, nav_files, texts);
    const leap: core.civil.Leap = if (declaration) |d| gnss.auxiliary.leapSchedule(d.declaration, reference) catch |e| {
        try leapDiagnostic(diags, d, reference, e);
        return error.InvalidInput;
    } else .table;
    if (declaration) |d| if (leap.event == null and leap.count != leap.table_insertions) {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = d.name, .path = d.path };
        try scope.warn(.no_record, null, "declares {d} leap seconds where the built-in history ends at {d}, without the week and day of the change: the UTC parameters are not broadcast", .{ leap.count, leap.table_insertions });
    };

    var pools: rinex.Pools = .{ .arena = arena, .leap = leap };
    var almanacs: std.ArrayList(records.Almanac) = .empty;
    var almanac_skipped: u32 = 0;
    var header: rinex.Header = .{};
    var ordinal = std.EnumArray(bundle.scenario.NavKind, usize).initFill(0);
    for (nav_files, texts) |file, text| {
        const i = ordinal.get(file.kind);
        ordinal.set(file.kind, i + 1);
        const path = try arena.print("{s}[{d}].name", .{ bundle.scenario.NavKind.words.get(file.kind), i });
        const scope: diagnostics.Scope = .{ .diags = diags, .source = file.path, .path = path };
        const is_almanac = almanac.detect(text) != null;
        switch (file.kind) {
            .almanac => if (!is_almanac) return scope.fail(.invalid_format, null, "expected an almanac file", .{}),
            .ephemeris => if (is_almanac) return scope.fail(.invalid_format, null, "an almanac file must be listed under almanac, not ephemeris", .{}),
        }
        if (is_almanac) {
            const a = try almanac.parse(arena, text, reference, leap, scope);
            const kept = try plausibleAlmanacs(arena, scope, a.almanacs);
            if (kept.len == 0) try scope.warn(.no_record, null, "the file gives no almanac", .{});
            var newest: std.ArrayList(records.Almanac) = .empty;
            for (kept) |candidate| try almanac.keepNewest(&newest, arena, candidate);
            try almanacs.appendSlice(arena, newest.items);
            almanac_skipped += a.skipped + @as(u32, @intCast(a.almanacs.len - kept.len));
            continue;
        }
        const first = pools.rejected.items.len;
        const records_before = pools.kepler.items.len + pools.glonass.items.len;
        const file_header = try rinex.parse(&pools, text, scope);
        try report(arena, scope, pools.rejected.items[first..]);
        if (pools.kepler.items.len + pools.glonass.items.len == records_before) {
            try scope.warn(.no_record, null, "the file gives no ephemeris record of GPS, Galileo, BDS or GLONASS", .{});
        }
        inline for (@typeInfo(core.iono.Broadcast).@"struct".field_names) |name| {
            if (@field(header.iono, name) == null) @field(header.iono, name) = try fitting(scope, name, @field(file_header.iono, name));
        }
        if (file_header.leap) |l| {
            if (header.leap) |earlier| {
                if (!std.meta.eql(l, earlier)) try scope.warn(.implausible_record, null, "declares {d} leap seconds where an earlier file declares {d}: the run flies the first declaration", .{ l.delta_tls, earlier.delta_tls });
            } else header.leap = l;
        }
    }

    header.iono = transmitted(pools.ions.items, reference, header.iono);
    return .{
        .set = .{
            .kepler = pools.kepler.items,
            .glonass = pools.glonass.items,
            .time_offsets = pools.time_offsets.items,
            .eops = pools.eops.items,
        },
        .header = header,
        .almanacs = almanacs.items,
        .leap = leap,
        .skipped = pools.skipped + almanac_skipped,
    };
}

fn declared(arena: std.mem.Allocator, nav_files: []const bundle.scenario.NavFile, texts: []const []const u8) std.mem.Allocator.Error!?Declared {
    var ordinal: usize = 0;
    for (nav_files, texts) |file, text| {
        if (file.kind != .ephemeris) continue;
        defer ordinal += 1;
        if (almanac.detect(text) != null) continue;
        const d = rinex.declaration(text) orelse continue;
        return .{ .declaration = d, .path = try arena.print("ephemeris[{d}].name", .{ordinal}), .name = file.path };
    }
    return null;
}

fn leapDiagnostic(diags: *Diagnostics, d: Declared, start: GpsTime, e: gnss.auxiliary.LeapError) std.mem.Allocator.Error!void {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = d.name, .path = d.path };
    switch (e) {
        error.LeapCountNegative => try scope.err(.out_of_range, null, "declares {d} leap seconds, a count below zero", .{d.declaration.delta_tls}),
        error.LeapCountDisagrees => try scope.err(.out_of_range, null, "declares {d} leap seconds where {d} were in force at the run start, {f}: inside the built-in history the data cannot declare another count", .{ d.declaration.delta_tls, core.civil.Leap.insertionsAt(start.ms), start.printed(null) }),
    }
}

fn plausibleAlmanacs(arena: std.mem.Allocator, scope: diagnostics.Scope, list: []records.Almanac) std.mem.Allocator.Error![]const records.Almanac {
    var rejected: std.ArrayList(rinex.Rejection) = .empty;
    var kept: usize = 0;
    for (list) |a| {
        const unfit = switch (a) {
            .kepler => |*k| gnss.plausible.almanac(k),
            .glonass => |*g| gnss.plausible.glonassAlmanac(g),
        };
        const name = unfit orelse {
            list[kept] = a;
            kept += 1;
            continue;
        };
        const sat = a.sat();
        try rejected.append(arena, .{
            .system = sat.system,
            .named = switch (a) {
                .kepler => |k| .{ .record = .{ .prn = sat.prn(), .epoch = k.toa.toCalendar() } },
                .glonass => |g| .{ .label = try arena.print("{f} N4 {d} NA {d}", .{ sat, g.n4, g.na }) },
            },
            .message = "almanac",
            .field = name,
        });
    }
    try report(arena, scope, rejected.items);
    return list[0..kept];
}

fn fitting(scope: diagnostics.Scope, comptime name: []const u8, set: anytype) std.mem.Allocator.Error!@TypeOf(set) {
    const value = set orelse return null;
    var one: core.iono.Broadcast = .{};
    @field(one, name) = value;
    if (gnss.plausible.broadcastIono(one)) |field| {
        try scope.warn(.implausible_record, null, "the {s} set of the header is dropped, {s} outside its broadcast field", .{ name, field });
        return null;
    }
    return value;
}

fn transmitted(ions: []const rinex.Ion, start: GpsTime, fallback: core.iono.Broadcast) core.iono.Broadcast {
    var out = fallback;
    inline for (@typeInfo(core.iono.Broadcast).@"struct".field_names) |name| {
        var best: ?rinex.Ion = null;
        for (ions) |ion| {
            if (@field(ion.set, name) == null or start.lessThan(ion.transmitted)) continue;
            if (best) |b| if (!b.transmitted.lessThan(ion.transmitted)) continue;
            best = ion;
        }
        if (best) |b| @field(out, name) = @field(b.set, name);
    }
    return out;
}

fn report(arena: std.mem.Allocator, scope: diagnostics.Scope, rejected: []const rinex.Rejection) std.mem.Allocator.Error!void {
    for (rejected, 0..) |r, i| {
        const same = struct {
            fn f(a: rinex.Rejection, b: rinex.Rejection) bool {
                return a.system == b.system and a.reason == b.reason and std.mem.eql(u8, a.message, b.message) and std.mem.eql(u8, a.field, b.field);
            }
        }.f;
        var seen = false;
        for (rejected[0..i]) |q| seen = seen or same(q, r);
        if (seen) continue;
        var names: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        for (rejected[i..]) |q| if (same(q, r)) {
            if (count < 3) {
                const separator = if (count > 0) ", " else "";
                switch (q.named) {
                    .record => |at| try names.print(arena, "{s}{c}{d:0>2} {f}", .{ separator, q.system.rinexLetter(), at.prn, at.epoch }),
                    .label => |label| try names.print(arena, "{s}{s}", .{ separator, label }),
                }
            }
            count += 1;
        };
        if (count > 3) try names.print(arena, " and {d} more", .{count - 3});
        var message: [8]u8 = undefined;
        const upper = std.ascii.upperString(&message, r.message[0..@min(r.message.len, message.len)]);
        const plural = if (count == 1) "" else "s";
        switch (r.reason) {
            .implausible => try scope.warn(.implausible_record, null, "{d} {s} {s} record{s} skipped, {s} outside its ICD range: {s}", .{ count, r.system.name(), upper, plural, r.field, names.items }),
            .blank => try scope.warn(.implausible_record, null, "{d} {s} {s} record{s} skipped, {s} blank: {s}", .{ count, r.system.name(), upper, plural, r.field, names.items }),
            .mismatch => try scope.warn(.implausible_record, null, "{d} {s} {s} block{s} skipped, the record line naming another satellite: {s}", .{ count, r.system.name(), upper, plural, names.items }),
            .malformed => try scope.warn(.implausible_record, null, "{d} {s} {s}{s}record{s} skipped, a line that does not read: {s}", .{ count, r.system.name(), upper, if (upper.len > 0) " " else "", plural, names.items }),
        }
    }
}

pub fn antenna(arena: std.mem.Allocator, source: files.Source, path: []const u8, diags: *Diagnostics) diagnostics.LoadError!bundle.antex.Antex {
    const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = "antenna" };
    const atx = try antex.parse(arena, try files.readResolved(arena, source, path, files.max_bytes, scope), scope);
    if (atx.antennas.len == 0) try scope.warn(.no_record, null, "the file gives no satellite antenna", .{});
    try warnAttitude(atx, scope);
    return atx;
}

fn warnAttitude(atx: bundle.antex.Antex, scope: diagnostics.Scope) std.mem.Allocator.Error!void {
    for (atx.antennas, 0..) |a, i| {
        if (a.law != .nominal) continue;
        var seen = false;
        for (atx.antennas[0..i]) |b| seen = seen or std.mem.eql(u8, a.kind, b.kind);
        if (seen) continue;
        try scope.warn(.no_record, null, "no yaw law is held for the antenna type {s}: its satellites fly the nominal law through their turns", .{a.kind});
    }
}

pub fn precise(arena: std.mem.Allocator, source: files.Source, p: bundle.scenario.Precise, leap: core.civil.Leap, diags: *Diagnostics) diagnostics.LoadError!*Product {
    var orbit: std.ArrayList(bundle.precise.OrbitSample) = .empty;
    var interval: ?f64 = null;
    var first_epoch: ?GpsTime = null;
    for (p.orbit, 0..) |path, index| {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = try arena.print("precise.orbit[{d}]", .{index}) };
        const file = try sp3.parse(arena, try files.readResolved(arena, source, path, files.max_bytes, scope), leap, scope);
        if (interval) |i| {
            if (i != file.interval_s) return scope.fail(.invalid_format, null, "the SP3 interval {d} s does not match the earlier files' {d} s", .{ file.interval_s, i });
        } else interval = file.interval_s;
        if (file.samples.len > 0) {
            if (first_epoch) |t0| {
                if (!sp3.onGrid(file.samples[0].t, t0, file.interval_s)) return scope.fail(.invalid_format, null, "the first SP3 epoch does not lie on the earlier files' sampling grid", .{});
            } else first_epoch = file.samples[0].t;
        }
        try orbit.appendSlice(arena, file.samples);
    }
    var clocks: std.ArrayList(bundle.precise.ClockRecord) = .empty;
    for (p.clock, 0..) |path, index| {
        const scope: diagnostics.Scope = .{ .diags = diags, .source = path, .path = try arena.print("precise.clock[{d}]", .{index}) };
        try clocks.appendSlice(arena, try clk.parse(arena, try files.readResolved(arena, source, path, files.max_bytes, scope), leap, scope));
    }
    const scope: diagnostics.Scope = .{ .diags = diags, .source = diags.source, .path = "precise" };
    const interval_s = interval orelse return scope.fail(.missing_field, null, "the precise product has no SP3 orbit file", .{});
    const product = try arena.create(Product);
    product.* = Product.build(arena, orbit.items, interval_s, clocks.items, p.clock_reference) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EmptyProduct => "the precise product has no orbit samples",
            error.SparseEpochs => "the precise product's orbit samples are too sparse",
            error.MalformedRecord => "the precise product has an orbit sample outside its sampling grid",
        };
        return scope.fail(.invalid_format, null, "{s}", .{message});
    };
    return product;
}
