const std = @import("std");
const diagnostics = @import("../core.zig").diagnostics;
const node = @import("../json/node.zig");
const trajectory = @import("../trajectory.zig");
const Trajectory = trajectory.Trajectory;
const Knot = trajectory.Knot;

const format_word = "pht";
const version: i64 = 1;
const frame = "ECEF";
const interpolation = "quintic-hermite";
const columns = [_][]const u8{ "t", "x", "y", "z", "vx", "vy", "vz", "ax", "ay", "az" };

const header_start = std.fmt.comptimePrint("{{\"format\":\"{s}\",\"version\":{d}", .{ format_word, version });
const header_end = blk: {
    var text: []const u8 = ",\"frame\":\"" ++ frame ++ "\",\"interpolation\":\"" ++ interpolation ++ "\",\"columns\":[";
    for (columns, 0..) |c, i| text = text ++ (if (i == 0) "" else ",") ++ "\"" ++ c ++ "\"";
    break :blk text ++ "]}\n";
};

pub const max_bytes: usize = 1 << 30;

const knot_line_budget_bytes: usize = 256;

pub const max_knots: usize = max_bytes / knot_line_budget_bytes;

pub const Error = diagnostics.InputError;

pub fn read(arena: std.mem.Allocator, bytes: []const u8, scope: diagnostics.Scope) Error!Trajectory {
    var body = bytes;
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    var count: ?i64 = null;
    var result = try header(arena, lineOf(lines.next() orelse ""), scope, &count);
    var knots: std.ArrayList(Knot) = .empty;
    var number: usize = 1;
    while (lines.next()) |raw| {
        number += 1;
        const line = lineOf(raw);
        if (line.len == 0 and lines.peek() == null) break;
        const value = knot(line) catch return scope.fail(.invalid_format, .{ .line = std.math.lossyCast(u32, number) }, "expected a knot array of 10 JSON numbers in [t,x,y,z,vx,vy,vz,ax,ay,az] order", .{});
        try knots.append(arena, value);
    }
    result.knots = knots.items;
    if (count) |given| if (given != knots.items.len) return scope.fail(.invalid_format, .{ .line = 1 }, "the header says {d} knots; the file has {d}", .{ given, knots.items.len });
    if (result.invalid()) |bad| {
        const code: diagnostics.Code = switch (bad.reason) {
            error.NoKnots, error.FirstKnotNotAtZero, error.TimeGoesBack, error.TimeGivenThrice, error.PositionJump => .invalid_format,
            else => .out_of_range,
        };
        return scope.fail(code, .{ .line = if (bad.location) |at| std.math.lossyCast(u32, at.knot + 2) else 2 }, "{s}", .{trajectory.reason(bad.reason)});
    }
    return result;
}

fn lineOf(raw: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
}

fn header(arena: std.mem.Allocator, line: []const u8, scope: diagnostics.Scope, count: *?i64) Error!Trajectory {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return scope.fail(.invalid_json, .{ .line = 1 }, "the PHT header: {s}", .{node.unparsed(e)}),
    };
    const obj = switch (value) {
        .object => |o| o,
        else => return scope.fail(.wrong_type, .{ .line = 1 }, "expected a PHT header object, found {s}", .{node.found(value)}),
    };
    const word = obj.get("format") orelse return scope.fail(.missing_field, .{ .line = 1 }, "header key \"format\" is required", .{});
    if (word != .string) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"format\" must be a string", .{});
    if (!std.mem.eql(u8, word.string, format_word)) return scope.fail(.invalid_format, .{ .line = 1 }, "header key \"format\" must be \"{s}\", got \"{f}\"", .{ format_word, diagnostics.Escaped{ .text = word.string } });
    var result: Trajectory = .{ .knots = &.{} };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "format")) continue;
        if (std.mem.eql(u8, key, "version")) {
            if (v != .integer) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"version\" must be an integer", .{});
            if (v.integer != version) return scope.fail(.invalid_format, .{ .line = 1 }, "unsupported PHT version {d}; expected {d}", .{ v.integer, version });
        } else if (std.mem.eql(u8, key, "knots")) {
            if (v != .integer) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"knots\" must be an integer", .{});
            count.* = v.integer;
        } else if (std.mem.eql(u8, key, "name")) {
            if (v != .string) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"name\" must be a string", .{});
            result.name = v.string;
        } else if (std.mem.eql(u8, key, "frame")) {
            if (v != .string) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"frame\" must be a string", .{});
            if (!std.mem.eql(u8, v.string, frame)) return scope.fail(.invalid_format, .{ .line = 1 }, "header key \"frame\" must be \"{s}\", got \"{f}\"", .{ frame, diagnostics.Escaped{ .text = v.string } });
        } else if (std.mem.eql(u8, key, "interpolation")) {
            if (v != .string) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"interpolation\" must be a string", .{});
            if (!std.mem.eql(u8, v.string, interpolation)) return scope.fail(.invalid_format, .{ .line = 1 }, "header key \"interpolation\" must be \"{s}\", got \"{f}\"", .{ interpolation, diagnostics.Escaped{ .text = v.string } });
        } else if (std.mem.eql(u8, key, "columns")) {
            if (v != .array) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"columns\" must be an array", .{});
            if (v.array.items.len != columns.len) return scope.fail(.invalid_format, .{ .line = 1 }, "header key \"columns\" must contain {d} names, got {d}", .{ columns.len, v.array.items.len });
            for (v.array.items, columns, 0..) |c, want, i| {
                if (c != .string) return scope.fail(.wrong_type, .{ .line = 1 }, "header key \"columns[{d}]\" must be a string", .{i});
                if (!std.mem.eql(u8, c.string, want)) return scope.fail(.invalid_format, .{ .line = 1 }, "header key \"columns[{d}]\" must be \"{s}\", got \"{f}\"", .{ i, want, diagnostics.Escaped{ .text = c.string } });
            }
        } else return scope.fail(.unknown_key, .{ .line = 1 }, "unknown PHT header key \"{f}\"; the keys here are format, version, knots, name, frame, interpolation, columns", .{diagnostics.Escaped{ .text = key }});
    }
    for ([_][]const u8{ "version", "frame", "interpolation", "columns" }) |required| {
        if (obj.get(required) == null) {
            return scope.fail(.missing_field, .{ .line = 1 }, "header key \"{s}\" is required", .{required});
        }
    }
    return result;
}

const blanks = " \t\r\n";

fn isNumber(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    const int_at = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == int_at or (s[int_at] == '0' and i - int_at > 1)) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_at = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == frac_at) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_at = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == exp_at) return false;
    }
    return i == s.len;
}

fn knot(line: []const u8) error{BadKnot}!Knot {
    const body = std.mem.trim(u8, line, blanks);
    if (body.len < 2 or body[0] != '[' or body[body.len - 1] != ']') return error.BadKnot;
    var n: [columns.len]f64 = undefined;
    var fields = std.mem.splitScalar(u8, body[1 .. body.len - 1], ',');
    var k: usize = 0;
    while (fields.next()) |field| : (k += 1) {
        if (k == columns.len) return error.BadKnot;
        const number = std.mem.trim(u8, field, blanks);
        if (!isNumber(number)) return error.BadKnot;
        n[k] = std.fmt.parseFloat(f64, number) catch return error.BadKnot;
    }
    if (k != columns.len) return error.BadKnot;
    return .{
        .t = n[0],
        .pos = .{ .x = n[1], .y = n[2], .z = n[3] },
        .vel = .{ .x = n[4], .y = n[5], .z = n[6] },
        .acc = .{ .x = n[7], .y = n[8], .z = n[9] },
    };
}

pub const WriteError = std.Io.Writer.Error || error{TooLarge};

/// Refused, as `error.TooLarge`, where the text would pass `max_bytes`, which every reader refuses: a knot's line is
/// as long as the shortest exact forms of its numbers, which `max_knots` does not bound.
pub fn write(w: *std.Io.Writer, traj: Trajectory) WriteError!void {
    var counted: std.Io.Writer.Discarding = .init(&.{});
    writeHeader(&counted.writer, traj) catch unreachable;
    var total = counted.fullCount();
    if (total > max_bytes) return error.TooLarge;
    try writeHeader(w, traj);
    // A number's shortest exact form takes at most 327 bytes (a subnormal's): a line, at most 3282.
    var buffer: [4096]u8 = undefined;
    for (traj.knots) |k| {
        const line = std.mem.print(&buffer, "[{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}]\n", .{ k.t, k.pos.x, k.pos.y, k.pos.z, k.vel.x, k.vel.y, k.vel.z, k.acc.x, k.acc.y, k.acc.z }) catch unreachable;
        total += line.len;
        if (total > max_bytes) return error.TooLarge;
        try w.writeAll(line);
    }
}

fn writeHeader(w: *std.Io.Writer, traj: Trajectory) std.Io.Writer.Error!void {
    try w.writeAll(header_start);
    try w.print(",\"knots\":{d}", .{traj.knots.len});
    if (traj.name.len > 0) {
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(traj.name, .{}, w);
    }
    try w.writeAll(header_end);
}
