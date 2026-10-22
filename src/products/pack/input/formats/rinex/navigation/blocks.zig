const std = @import("std");
const glonass_records = @import("products/pack/input/navigation/records/glonass");
const ionosphere_model = @import("domain/propagation/ionosphere/model");
const time = @import("domain/time/gps");
const navigation = @import("products/pack/input/admission/navigation");
const rinex_fields = @import("products/pack/input/formats/rinex/navigation/fields");
const rinex_records = @import("products/pack/input/formats/rinex/navigation/records");
const gnss_types = @import("domain/gnss_types");
const rinex_aux = @import("products/pack/input/formats/rinex/navigation/auxiliary");
const fields = @import("products/pack/input/navigation/fields");

const Error = std.mem.Allocator.Error;
const nextInBlock = rinex_fields.nextInBlock;

const Kind = enum { eph, ion, sto, eop, other };

const Block = struct { kind: Kind, system: ?gnss_types.System, sat_letter: ?u8, prn: ?u32, msg: []const u8 };

const Matched = struct { epoch: rinex_fields.Epoch, prn: u32 };

pub fn block(pools: *rinex_records.Pools, line: []const u8, lines: *rinex_fields.Lines) Error!void {
    const b = blockHeader(line);
    switch (b.kind) {
        .eph => try ephemeris(pools, b, lines),
        .ion => try ionosphere(pools, b, lines),
        .sto => try timeOffset(pools, b, lines),
        .eop => try earthOrientation(pools, b, lines),
        .other => skipRecord(pools, lines),
    }
}

fn blockHeader(line: []const u8) Block {
    var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
    const kind_s = it.next() orelse "";
    const sat_s = it.next() orelse "";
    const msg = it.next() orelse "";
    const kinds = std.StaticStringMap(Kind).initComptime(.{ .{ "EPH", .eph }, .{ "ION", .ion }, .{ "STO", .sto }, .{ "EOP", .eop } });
    const kind = kinds.get(kind_s) orelse .other;
    const system: ?gnss_types.System = if (sat_s.len == 0) null else gnss_types.System.fromRinexLetter(sat_s[0]);
    const prn: ?u32 = if (sat_s.len >= 3) std.fmt.parseInt(u32, sat_s[1..3], 10) catch null else null;
    return .{ .kind = kind, .system = system, .sat_letter = if (sat_s.len > 0) sat_s[0] else null, .prn = prn, .msg = msg };
}

fn skipBlock(lines: *rinex_fields.Lines) void {
    while (nextInBlock(lines) != null) {}
}

fn skipRecord(pools: *rinex_records.Pools, lines: *rinex_fields.Lines) void {
    pools.issues.ignore();
    skipBlock(lines);
}

fn ephemeris(pools: *rinex_records.Pools, b: Block, lines: *rinex_fields.Lines) Error!void {
    const system = b.system orelse return skipRecord(pools, lines);
    switch (system) {
        .glo => {
            if (glonass_records.kind(b.msg) == null) return skipRecord(pools, lines);
            const matched = try recordEpoch(pools, system, b, lines) orelse return skipBlock(lines);
            const ep = matched.epoch;
            const body = try rinex_records.glonassBody(pools, matched.prn, ep, lines) orelse return skipBlock(lines);
            const fourth: ?[4]?f64 = if (nextInBlock(lines)) |status| rinex_fields.bodyColumns(status) catch {
                try rinex_records.rejectMalformed(pools, .glo, matched.prn, ep, "fdma");
                return skipBlock(lines);
            } else null;
            const rec = try rinex_records.glonassRecord(pools, matched.prn, ep, &body, fourth);
            if (rec) |r| try pools.glonass.append(pools.arena, r);
        },
        inline .gps, .gal, .bds => |sys| {
            const kind = rinex_records.systemRecord(sys).kind(b.msg) orelse return skipRecord(pools, lines);
            const matched = try recordEpoch(pools, system, b, lines) orelse return skipBlock(lines);
            const ep = matched.epoch;
            const rec = try rinex_records.keplerRecord(sys, pools, kind, matched.prn, ep, lines);
            if (rec) |r| try pools.kepler.append(pools.arena, r);
        },
    }
}

fn recordEpoch(pools: *rinex_records.Pools, system: gnss_types.System, b: Block, lines: *rinex_fields.Lines) Error!?Matched {
    const line = std.mem.trimEnd(u8, nextInBlock(lines) orelse "", "\r");
    const epoch = rinex_fields.epochLine(line) catch {
        const label = if (line.len > 0) line[0..@min(line.len, 23)] else try pools.arena.print("{c}{d:0>2}", .{ system.rinexLetter(), b.prn orelse 0 });
        try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .label = label }, .message = b.msg, .reason = .malformed });
        return null;
    };
    const prn = if (line.len >= 3 and line[0] == b.sat_letter) std.fmt.parseInt(u32, std.mem.trim(u8, line[1..3], " "), 10) catch null else null;
    if (prn) |p| if (b.prn == p) return .{ .epoch = epoch, .prn = p };
    try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .record = .{ .prn = b.prn orelse 0, .epoch = epoch.utc } }, .message = b.msg, .reason = .mismatch });
    return null;
}

fn rejectBlock(pools: *rinex_records.Pools, system: gnss_types.System, message: []const u8, first: []const u8, lines: *rinex_fields.Lines) std.mem.Allocator.Error!void {
    try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .label = first[0..@min(first.len, 23)] }, .message = message, .reason = .malformed });
    skipBlock(lines);
}

fn ionosphereValues(first: []const u8, lines: *rinex_fields.Lines, count: usize) fields.Error![9]f64 {
    var v: [9]f64 = @splat(0);
    for (v[0..3], 0..) |*x, i| x.* = try fields.required(first, 23 + 19 * i, 19);
    var filled: usize = 3;
    while (filled < count) {
        const line = nextInBlock(lines) orelse return error.MalformedRecord;
        const end = @min(filled + 4, count);
        for (v[filled..end], 0..) |*x, i| x.* = try fields.required(line, 4 + 19 * i, 19);
        filled = end;
    }
    return v;
}

fn ionosphere(pools: *rinex_records.Pools, b: Block, lines: *rinex_fields.Lines) Error!void {
    const system = b.system orelse return skipRecord(pools, lines);
    const count: usize = switch (system) {
        .gps => 8,
        .gal => 3,
        .bds => if (std.mem.eql(u8, b.msg, "CNVX")) 9 else if (std.mem.eql(u8, b.msg, "D1D2")) 8 else return skipRecord(pools, lines),
        .glo => return skipRecord(pools, lines),
    };
    const first = std.mem.trimEnd(u8, nextInBlock(lines) orelse return rejectBlock(pools, system, "ion", "", lines), "\r");
    const epoch = rinex_fields.calendar(first) catch return rejectBlock(pools, system, "ion", first, lines);
    const v = ionosphereValues(first, lines, count) catch return rejectBlock(pools, system, "ion", first, lines);
    skipBlock(lines);
    var set: ionosphere_model.SuppliedCoefficients = .{};
    switch (system) {
        .gps => set.klobuchar = .{ .alpha = v[0..4].*, .beta = v[4..8].* },
        .bds => if (std.mem.eql(u8, b.msg, "CNVX")) {
            set.bdgim = v[0..9].*;
        } else if (std.mem.eql(u8, b.msg, "D1D2")) {
            set.bds_klobuchar = .{ .alpha = v[0..4].*, .beta = v[4..8].* };
        } else return,
        .gal => set.nequick = .fromArray(v[0..3].*),
        .glo => return,
    }
    if (navigation.broadcastIono(set)) |name| {
        try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .record = .{ .prn = b.prn orelse 0, .epoch = epoch } }, .message = "ion", .field = name });
        return;
    }
    const transmitted = rinex_aux.inSystem(system, time.GpsTime.fromGpsCalendar(epoch), pools.leap);
    try pools.ions.append(pools.arena, .{ .transmitted = transmitted, .set = set });
}

fn timeOffset(pools: *rinex_records.Pools, b: Block, lines: *rinex_fields.Lines) Error!void {
    const system = b.system orelse return skipRecord(pools, lines);
    const msg = rinex_aux.message(b.msg) orelse return skipRecord(pools, lines);
    const first = nextInBlock(lines) orelse return rejectBlock(pools, system, "sto", "", lines);
    const second = nextInBlock(lines) orelse return rejectBlock(pools, system, "sto", first, lines);
    const parsed = rinex_aux.sto(system, msg, first, second, pools.leap) catch return rejectBlock(pools, system, "sto", first, lines);
    if (parsed) |offset| {
        if (navigation.timeOffset(offset.record)) |name| {
            try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .record = .{ .prn = b.prn orelse 0, .epoch = offset.epoch } }, .message = "sto", .field = name });
        } else try pools.time_offsets.append(pools.arena, offset.record);
    } else pools.issues.ignore();
    skipBlock(lines);
}

fn earthOrientation(pools: *rinex_records.Pools, b: Block, lines: *rinex_fields.Lines) Error!void {
    const system = b.system orelse return skipRecord(pools, lines);
    const msg = rinex_aux.message(b.msg) orelse return skipRecord(pools, lines);
    var body: [3][]const u8 = undefined;
    for (&body, 0..) |*row, i| row.* = nextInBlock(lines) orelse return rejectBlock(pools, system, "eop", if (i == 0) "" else body[0], lines);
    const orientation = rinex_aux.eop(system, msg, body, pools.leap) catch |err| {
        if (err == error.InvalidDut1) {
            try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .label = body[0][0..@min(body[0].len, 23)] }, .message = "eop", .field = "dut1" });
            skipBlock(lines);
            return;
        }
        return rejectBlock(pools, system, "eop", body[0], lines);
    };
    if (navigation.eop(&orientation.record)) |name| {
        try pools.issues.add(pools.arena, .{ .system = system, .named = .{ .record = .{ .prn = b.prn orelse 0, .epoch = orientation.epoch } }, .message = "eop", .field = name });
    } else try pools.eops.append(pools.arena, orientation.record);
    skipBlock(lines);
}
