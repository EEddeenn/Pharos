const std = @import("std");
const core = @import("shared").core;
const gnss = @import("shared").gnss;
const time = core.time;
const iono = core.iono;
const auxiliary = gnss.auxiliary;
const fields = @import("../fields.zig");
const rinex_fields = @import("fields.zig");
const rinex_aux = @import("aux.zig");
const rinex_records = @import("records.zig");
const Pools = rinex_records.Pools;

pub const Header = struct {
    iono: iono.Broadcast = .{},
    leap: ?auxiliary.LeapDeclaration = null,
};

const Half = struct { values: [4]f64, key: [4]u8 };

const Klobuchar = struct { alpha: ?Half = null, beta: ?Half = null };

pub const State = struct { gps: Klobuchar = .{}, bds: Klobuchar = .{} };

fn klobucharHalf(k: *Klobuchar, out: *?iono.klobuchar.Model, alpha: bool, half: Half) void {
    if (alpha) k.alpha = half else k.beta = half;
    const a = k.alpha orelse return;
    const b = k.beta orelse return;
    if (std.mem.eql(u8, &a.key, &b.key)) out.* = .{ .alpha = a.values, .beta = b.values };
}

fn rejectHeaderLine(pools: *Pools, system: core.types.System, label: []const u8, field: [:0]const u8, reason: rinex_records.Reason) std.mem.Allocator.Error!void {
    try pools.rejected.append(pools.arena, .{ .system = system, .named = .{ .label = label }, .message = "header", .field = field, .reason = reason });
}

fn ionosphereSystem(key: []const u8) core.types.System {
    if (std.mem.startsWith(u8, key, "BDS")) return .bds;
    return if (std.mem.startsWith(u8, key, "GAL")) .gal else .gps;
}

const Label = enum { ionospheric_corr, time_system_corr, leap_seconds, end_of_header };
const labels = std.StaticStringMap(Label).initComptime(.{ .{ "IONOSPHERIC CORR", .ionospheric_corr }, .{ "TIME SYSTEM CORR", .time_system_corr }, .{ "LEAP SECONDS", .leap_seconds }, .{ "END OF HEADER", .end_of_header } });

pub fn readLine(pools: *Pools, line: []const u8, header: *Header, state: *State) std.mem.Allocator.Error!void {
    switch (labels.get(fields.label(line)) orelse return) {
        .ionospheric_corr => {
            const key = line[0..4];
            const system = ionosphereSystem(key);
            var values: [4]f64 = .{ 0, 0, 0, 0 };
            for (values[0..if (system == .gal) 3 else 4], 0..) |*v, i| v.* = fields.required(line, 5 + 12 * i, 12) catch return rejectHeaderLine(pools, system, key, "", .malformed);
            const half: Half = .{ .values = values, .key = line[54..58].* };
            if (std.mem.eql(u8, key, "GPSA") or std.mem.eql(u8, key, "GPSB")) {
                klobucharHalf(&state.gps, &header.iono.klobuchar, key[3] == 'A', half);
            } else if (std.mem.eql(u8, key, "BDSA") or std.mem.eql(u8, key, "BDSB")) {
                klobucharHalf(&state.bds, &header.iono.bds_klobuchar, key[3] == 'A', half);
            } else if (system == .gal) {
                header.iono.nequick = .fromArray(values[0..3].*);
            }
        },
        .time_system_corr => {
            const parsed = rinex_aux.header(line) catch return rejectHeaderLine(pools, .gps, line[0..4], "", .malformed);
            const offset = parsed orelse return;
            if (gnss.plausible.timeOffset(offset)) |name| {
                try rejectHeaderLine(pools, rinex_aux.systemOf(offset.kind), line[0..4], name, .implausible);
            } else try pools.time_offsets.append(pools.arena, offset);
        },
        .leap_seconds => {
            const declared = leapRecord(line) catch return rejectHeaderLine(pools, .gps, line[60..72], "", .malformed);
            if (declared.misfit()) |name| {
                try rejectHeaderLine(pools, .gps, line[60..72], name, .implausible);
                header.leap = .{ .delta_tls = declared.delta_tls };
            } else header.leap = declared;
        },
        .end_of_header => {},
    }
}

fn leapRecord(line: []const u8) fields.Error!auxiliary.LeapDeclaration {
    const bds = std.mem.eql(u8, line[24..27], "BDS");
    const out: auxiliary.LeapDeclaration = .{ .delta_tls = try leapCount(try fields.intAt(i64, line, 0, 6), bds) };
    const tlsf = rinex_fields.optionalInt(line, 6, 6) orelse return out;
    const wn_lsf = rinex_fields.optionalInt(line, 12, 6) orelse return out;
    const dn = rinex_fields.optionalInt(line, 18, 6) orelse return out;
    if (if (bds) dn < 0 or dn > 6 else dn < 1 or dn > 7) return error.MalformedRecord;
    return .{
        .delta_tls = out.delta_tls,
        .announced = .{
            .delta_tlsf = try leapCount(tlsf, bds),
            .wn_lsf = @intCast(@mod(wn_lsf + (if (bds) time.bds_week_offset else @as(i64, 0)), time.week_modulus_16)),
            .dn = @intCast(if (bds) dn + 1 else dn),
        },
    };
}

pub fn declaration(source: []const u8) ?auxiliary.LeapDeclaration {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        switch (labels.get(fields.label(line)) orelse continue) {
            .end_of_header => return null,
            .leap_seconds => return leapRecord(line) catch null,
            else => {},
        }
    }
    return null;
}

fn leapCount(value: i64, bds: bool) fields.Error!i8 {
    return std.math.cast(i8, value + (if (bds) @as(i64, 14) else 0)) orelse error.MalformedRecord;
}
