const std = @import("std");
const diagnostics = @import("base/diagnostics");
const gnss_types = @import("domain/gnss_types");
const auxiliary = @import("domain/navigation/system_data");
const fields = @import("products/pack/input/navigation/fields");
const rinex_fields = @import("products/pack/input/formats/rinex/navigation/fields");
const rinex_records = @import("products/pack/input/formats/rinex/navigation/records");
const header = @import("products/pack/input/formats/rinex/navigation/header");
const blocks = @import("products/pack/input/formats/rinex/navigation/blocks");

pub const Header = header.Header;
pub const Pools = rinex_records.Pools;
pub const Ion = rinex_records.Ion;
pub const HeaderRead = struct {
    metadata: Header,
    offsets: []const auxiliary.TimeOffset,
    version: f64,
    body_offset: usize,
};

const first_version = 3.0;
const unsupported_version = 5.0;
const glonass_status_version = 3.05;

pub fn readHeader(arena: std.mem.Allocator, source: []const u8, scope: diagnostics.Scope) diagnostics.InputError!HeaderRead {
    var lines = std.mem.splitScalar(u8, source, '\n');
    const first = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
    if (!std.mem.eql(u8, fields.label(first), "RINEX VERSION / TYPE") or first[20] != 'N') return scope.fail(.invalid_format, .{ .text = .{ .line = 1 } }, "expected a RINEX navigation file", .{});
    const version = fields.float(fields.column(first, 0, 9) orelse "") orelse return scope.fail(.invalid_format, .{ .text = .{ .line = 1 } }, "the RINEX version cannot be read", .{});
    if (version < first_version or version >= unsupported_version) return scope.fail(.invalid_format, .{ .text = .{ .line = 1 } }, "the RINEX navigation version is unsupported; expected version 3 or 4", .{});
    var pools: Pools = .{ .arena = arena };
    var metadata: Header = .{};
    var state: header.State = .{};
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, fields.label(line), "END OF HEADER")) {
            try pools.issues.report(scope);
            return .{ .metadata = metadata, .offsets = pools.time_offsets.items, .version = version, .body_offset = lines.index orelse source.len };
        }
        try header.readLine(&pools, line, &metadata, &state);
    }
    try pools.issues.report(scope);
    return scope.fail(.invalid_format, null, "the RINEX navigation header has no END OF HEADER line", .{});
}

pub fn readBody(pools: *Pools, source: []const u8, identified: HeaderRead) std.mem.Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, source[identified.body_offset..], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '>') {
            try blocks.block(pools, line, &lines);
            continue;
        }
        if (line[0] == ' ') continue;
        const sys = gnss_types.System.fromRinexLetter(line[0]) orelse {
            pools.issues.ignore();
            while (rinex_fields.continuation(&lines) != null) {}
            continue;
        };
        const prn = fields.intAt(u32, line, 1, 2) catch {
            try rinex_records.rejectLine(pools, sys, line);
            continue;
        };
        const ep = rinex_fields.epochLine(line) catch {
            try rinex_records.rejectLine(pools, sys, line);
            continue;
        };
        switch (sys) {
            .glo => {
                const body = try rinex_records.glonassBody(pools, prn, ep, &lines) orelse {
                    continue;
                };
                const fourth: ?[4]?f64 = if (identified.version < glonass_status_version) null else if (rinex_fields.continuation(&lines)) |status| rinex_fields.bodyColumns(status) catch {
                    try rinex_records.rejectMalformed(pools, .glo, prn, ep, "fdma");
                    continue;
                } else null;
                if (try rinex_records.glonassRecord(pools, prn, ep, &body, fourth)) |rec| try pools.glonass.append(pools.arena, rec);
            },
            inline .gps, .gal, .bds => |s| {
                const kind = rinex_records.systemRecord(s).rinex3_kind;
                if (try rinex_records.keplerRecord(s, pools, kind, prn, ep, &lines)) |rec| try pools.kepler.append(pools.arena, rec);
            },
        }
    }
}
