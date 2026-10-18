const std = @import("std");
const bundle = @import("../bundle.zig");
const diagnostics = @import("../core.zig").diagnostics;

const magic = "PHB1";
const version: u32 = 1;

const Error = error{ OutOfMemory, EndOfStream, BadMagic, BadVersion, BadLayout, Corrupt };

const layout = describe(bundle.Bundle);
pub const header_len = magic.len + 4 + 8;

fn layoutHash() u64 {
    return std.hash.Wyhash.hash(0, layout);
}

pub fn write(w: *std.Io.Writer, value: *const bundle.Bundle) std.Io.Writer.Error!void {
    try w.writeAll(magic);
    try w.writeInt(u32, version, .little);
    try w.writeInt(u64, layoutHash(), .little);
    try encode(w, bundle.Bundle, value.*);
}

pub fn read(arena: std.mem.Allocator, bytes: []const u8, scope: diagnostics.Scope) diagnostics.InputError!bundle.Bundle {
    var r: Reader = .{ .bytes = bytes, .arena = arena };
    const value = decodeBundle(&r) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return scope.fail(.invalid_format, null, "{s}", .{reason(e)});
    };
    if (r.pos != bytes.len) {
        return scope.fail(.invalid_format, null, "the file carries bytes after the bundle", .{});
    }
    if (value.validate()) |failed| {
        return scope.fail(.invalid_format, null, "{s}", .{failed});
    }
    return value;
}

fn reason(e: Error) []const u8 {
    return switch (e) {
        error.BadMagic => "the file does not begin with a bundle header; pharos-pack writes the .phb files",
        error.BadVersion => "the bundle format version is not this build's; re-run pharos-pack on the scenario",
        error.BadLayout => "the bundle was written by a build of pharos-pack with other bundle types; re-run pharos-pack on the scenario",
        error.EndOfStream => "the file ends inside the bundle: it is truncated",
        error.Corrupt => "a value or a cross-reference does not hold",
        error.OutOfMemory => "out of memory",
    };
}

pub fn checkHeader(bytes: []const u8, scope: diagnostics.Scope) diagnostics.InputError!void {
    return decodeHeader(bytes) catch |e| scope.fail(.invalid_format, null, "{s}", .{reason(e)});
}

fn decodeHeader(bytes: []const u8) Error!void {
    if (bytes.len < header_len) return error.EndOfStream;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
    if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != version) return error.BadVersion;
    if (std.mem.readInt(u64, bytes[magic.len + 4 ..][0..8], .little) != layoutHash()) return error.BadLayout;
}

fn decodeBundle(r: *Reader) Error!bundle.Bundle {
    try decodeHeader(r.bytes);
    r.pos = header_len;
    return r.decode(bundle.Bundle);
}

fn isEnumMap(comptime T: type) bool {
    return @hasDecl(T, "Key") and @hasDecl(T, "Value") and @hasField(T, "bits") and @hasField(T, "values");
}

fn Aligned(comptime T: type) type {
    return std.math.ByteAlignedInt(T);
}

fn Bits(comptime F: type) type {
    return @Int(.unsigned, @bitSizeOf(F));
}

fn encode(w: *std.Io.Writer, comptime T: type, value: T) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .int => try w.writeInt(Aligned(T), value, .little),
        .float => try w.writeInt(Bits(T), @bitCast(value), .little),
        .bool => try w.writeByte(@intFromBool(value)),
        .void => {},
        .@"enum" => try w.writeInt(u32, @backingInt(value), .little),
        .optional => |o| {
            if (value) |v| {
                try w.writeByte(1);
                try encode(w, o.child, v);
            } else try w.writeByte(0);
        },
        .array => |a| for (value) |item| try encode(w, a.child, item),
        .pointer => |p| switch (p.size) {
            .slice => {
                try w.writeInt(u64, value.len, .little);
                if (p.child == u8) try w.writeAll(value) else for (value) |item| try encode(w, p.child, item);
            },
            .one => try encode(w, p.child, value.*),
            else => @compileError("no bundle encoding for " ++ @typeName(T)),
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                try encode(w, s.backing_integer.?, @bitCast(value));
            } else if (comptime isEnumMap(T)) {
                inline for (comptime std.meta.tags(T.Key)) |k| try encode(w, ?T.Value, value.get(k));
            } else inline for (s.field_names, s.field_types) |name, Field| try encode(w, Field, @field(value, name));
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("untagged union in a bundle: " ++ @typeName(T));
            try w.writeInt(u32, @backingInt(value), .little);
            switch (value) {
                inline else => |payload, tag| try encode(w, @FieldType(T, @tagName(tag)), payload),
            }
        },
        else => @compileError("no bundle encoding for " ++ @typeName(T)),
    }
}

const Reader = struct {
    bytes: []const u8,
    arena: std.mem.Allocator,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.bytes.len - self.pos < n) return error.EndOfStream;
        const s = self.bytes[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        const A = Aligned(T);
        const n = @divExact(@typeInfo(A).int.bits, 8);
        const raw = std.mem.readInt(A, (try self.take(n))[0..n], .little);
        return std.math.cast(T, raw) orelse error.Corrupt;
    }

    fn enumeration(self: *Reader, comptime E: type) Error!E {
        return std.enums.fromInt(E, try self.int(u32)) orelse error.Corrupt;
    }

    fn decode(self: *Reader, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .int => return self.int(T),
            .float => {
                const v: T = @bitCast(try self.int(Bits(T)));
                return if (std.math.isFinite(v)) v else error.Corrupt;
            },
            .bool => return switch ((try self.take(1))[0]) {
                0 => false,
                1 => true,
                else => error.Corrupt,
            },
            .void => return {},
            .@"enum" => return self.enumeration(T),
            .optional => |o| return switch ((try self.take(1))[0]) {
                0 => null,
                1 => try self.decode(o.child),
                else => error.Corrupt,
            },
            .array => |a| {
                var out: T = undefined;
                for (&out) |*item| item.* = try self.decode(a.child);
                return out;
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    const len = std.math.cast(usize, try self.int(u64)) orelse return error.Corrupt;
                    if (p.child == u8) return try self.arena.dupe(u8, try self.take(len));
                    if (len > self.bytes.len - self.pos) return error.Corrupt;
                    const out = try self.arena.alloc(p.child, len);
                    for (out) |*item| item.* = try self.decode(p.child);
                    return out;
                },
                .one => {
                    const out = try self.arena.create(p.child);
                    out.* = try self.decode(p.child);
                    return out;
                },
                else => @compileError("no bundle decoding for " ++ @typeName(T)),
            },
            .@"struct" => |s| {
                if (s.layout == .@"packed") return @bitCast(try self.decode(s.backing_integer.?));
                if (comptime isEnumMap(T)) {
                    var out: T = .{};
                    inline for (comptime std.meta.tags(T.Key)) |k| {
                        if (try self.decode(?T.Value)) |v| out.put(k, v);
                    }
                    return out;
                }
                var out: T = undefined;
                inline for (s.field_names, s.field_types) |name, Field| @field(out, name) = try self.decode(Field);
                return out;
            },
            .@"union" => |u| {
                const Tag = u.tag_type orelse @compileError("untagged union in a bundle: " ++ @typeName(T));
                switch (try self.enumeration(Tag)) {
                    inline else => |tag| return @unionInit(T, @tagName(tag), try self.decode(@FieldType(T, @tagName(tag)))),
                }
            },
            else => @compileError("no bundle decoding for " ++ @typeName(T)),
        }
    }
};

fn describe(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(4_000_000);
        switch (@typeInfo(T)) {
            .int => |i| {
                if (T == usize or T == isize) @compileError("a bundle field cannot have the target's pointer width: " ++ @typeName(T));
                return @typeName(@Int(i.signedness, i.bits));
            },
            .float => return @typeName(T),
            .bool => return "bool",
            .void => return "void",
            .@"enum" => |e| {
                var out: []const u8 = "enum(" ++ describe(e.tag_type) ++ "){";
                for (e.field_names, e.field_values) |name, value| out = out ++ name ++ "=" ++ std.fmt.comptimePrint("{d}", .{value}) ++ ",";
                return out ++ "}";
            },
            .optional => |o| return "?" ++ describe(o.child),
            .array => |a| return "[" ++ std.fmt.comptimePrint("{d}", .{a.len}) ++ "]" ++ describe(a.child),
            .pointer => |p| return (if (p.size == .slice) "[]" else "*") ++ describe(p.child),
            .@"struct" => |s| {
                if (isEnumMap(T)) return "map(" ++ describe(T.Key) ++ "," ++ describe(T.Value) ++ ")";
                var out: []const u8 = if (@hasDecl(T, "Indexer")) "keyed(" ++ describe(T.Key) ++ ")" else "";
                out = out ++ if (s.layout == .@"packed") "packed(" ++ describe(s.backing_integer.?) ++ "){" else "struct{";
                for (s.field_names, s.field_types) |name, Field| out = out ++ name ++ ":" ++ describe(Field) ++ ",";
                return out ++ "}";
            },
            .@"union" => |u| {
                const Tag = u.tag_type orelse @compileError("untagged union in a bundle: " ++ @typeName(T));
                var out: []const u8 = "union(" ++ describe(Tag) ++ "){";
                for (u.field_names, u.field_types) |name, Field| out = out ++ name ++ ":" ++ describe(Field) ++ ",";
                return out ++ "}";
            },
            else => @compileError("no bundle layout for " ++ @typeName(T)),
        }
    }
}
