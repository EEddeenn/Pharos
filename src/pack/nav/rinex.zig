const std = @import("std");
const diagnostics = @import("shared").core.diagnostics;
const types = @import("shared").core.types;
const fields = @import("fields.zig");
const rinex_fields = @import("rinex/fields.zig");
const rinex_records = @import("rinex/records.zig");
const header = @import("rinex/header.zig");
const blocks = @import("rinex/blocks.zig");

const Error = rinex_fields.Error;
pub const Header = header.Header;
pub const Pools = rinex_records.Pools;
pub const Ion = rinex_records.Ion;
pub const Rejection = rinex_records.Rejection;
pub const declaration = header.declaration;

const first_version = 3.0;
const glonass_status_version = 3.05;
const unsupported_version = 5.0;

pub fn parse(pools: *Pools, source: []const u8, scope: diagnostics.Scope) diagnostics.InputError!Header {
    var at: usize = 0;
    return parseRaw(pools, source, &at) catch |e| {
        const message = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotNavigation => "expected a RINEX navigation file",
            error.UnsupportedVersion => "the RINEX navigation version is unsupported; expected version 3 or 4",
            error.MissingEndOfHeader => "the RINEX navigation header has no END OF HEADER line",
            error.MalformedRecord => "a RINEX navigation record is malformed",
        };
        return scope.fail(.invalid_format, if (at == 0) null else .{ .line = @intCast(at) }, "{s}", .{message});
    };
}

fn parseRaw(pools: *Pools, source: []const u8, at: *usize) Error!Header {
    var lines = std.mem.splitScalar(u8, source, '\n');
    errdefer at.* = fields.lineOf(source, lines.index);
    var sets: Header = .{};
    var state: header.State = .{};
    const first = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
    if (!std.mem.eql(u8, fields.label(first), "RINEX VERSION / TYPE") or first[20] != 'N') return error.NotNavigation;
    const version = fields.float(fields.column(first, 0, 9) orelse "") orelse return error.NotNavigation;
    if (version < first_version or version >= unsupported_version) return error.UnsupportedVersion;
    const ended = while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, fields.label(line), "END OF HEADER")) break true;
        try header.readLine(pools, line, &sets, &state);
    } else false;
    if (!ended) return error.MissingEndOfHeader;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '>') {
            try blocks.block(pools, line, &lines);
            continue;
        }
        if (line[0] == ' ') continue;
        const sys = types.System.fromRinexLetter(line[0]) orelse {
            pools.skipped += 1;
            const body: usize = if (line[0] == 'S') 3 else 7;
            for (0..body) |_| _ = lines.next();
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
                    pools.skipped += 1;
                    continue;
                };
                const fourth: ?[4]?f64 = if (version < glonass_status_version) null else if (rinex_fields.continuation(&lines)) |status| rinex_fields.bodyColumns(status) catch {
                    try rinex_records.rejectMalformed(pools, .glo, prn, ep, "fdma");
                    pools.skipped += 1;
                    continue;
                } else null;
                if (try rinex_records.glonassRecord(pools, prn, ep, &body, fourth)) |rec| try pools.glonass.append(pools.arena, rec) else pools.skipped += 1;
            },
            inline .gps, .gal, .bds => |s| {
                const kind = rinex_records.systemRecord(s).rinex3_kind;
                if (try rinex_records.keplerRecord(s, pools, kind, prn, ep, &lines)) |rec| try pools.kepler.append(pools.arena, rec) else pools.skipped += 1;
            },
        }
    }
    return sets;
}
