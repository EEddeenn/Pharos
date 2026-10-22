const std = @import("std");
const diagnostics = @import("base/diagnostics");

pub const Error = error{ OutOfMemory, EndOfStream, Corrupt };

pub const Reader = struct {
    bytes: []const u8,
    arena: std.mem.Allocator,
    pos: usize = 0,
    failure_at: ?usize = null,

    pub fn decode(self: *Reader, comptime T: type) Error!T {
        comptime fixedWidth(T);
        const start = self.pos;
        errdefer if (self.failure_at == null) {
            self.failure_at = start;
        };
        switch (@typeInfo(T)) {
            .int => return self.int(T),
            .float => return @bitCast(try self.int(Bits(T))),
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
                else => @compileError("no cache decoding for " ++ @typeName(T)),
            },
            .@"struct" => |s| {
                if (s.layout == .@"packed") return @bitCast(try self.decode(s.backing_integer.?));
                if (comptime isEnumMap(T)) {
                    var out: T = .{};
                    inline for (comptime std.enums.values(T.Key)) |k| {
                        if (try self.decode(?T.Value)) |v| out.put(k, v);
                    }
                    return out;
                }
                var out: T = undefined;
                inline for (s.field_names, s.field_types) |name, Field| @field(out, name) = try self.decode(Field);
                return out;
            },
            .@"union" => |u| {
                const Tag = u.tag_type orelse @compileError("untagged union in a cache: " ++ @typeName(T));
                switch (try self.enumeration(Tag)) {
                    inline else => |tag| return @unionInit(T, @tagName(tag), try self.decode(@FieldType(T, @tagName(tag)))),
                }
            },
            else => @compileError("no cache decoding for " ++ @typeName(T)),
        }
    }

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
};

pub fn refuse(scope: diagnostics.Scope, err: Error, offset: usize) diagnostics.InputError {
    const code: diagnostics.Code, const why: []const u8 = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream => .{ .cache_truncated, "the cache ends inside a value: it is truncated" },
        error.Corrupt => .{ .cache_invalid_value, "a value cannot be decoded in the cache's representation" },
    };
    return scope.fail(code, .{ .byte_offset = offset }, "{s}", .{why});
}

pub fn encode(w: *std.Io.Writer, comptime T: type, value: T) std.Io.Writer.Error!void {
    comptime fixedWidth(T);
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
            else => @compileError("no cache encoding for " ++ @typeName(T)),
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                try encode(w, s.backing_integer.?, @bitCast(value));
            } else if (comptime isEnumMap(T)) {
                inline for (comptime std.enums.values(T.Key)) |k| try encode(w, ?T.Value, value.get(k));
            } else inline for (s.field_names, s.field_types) |name, Field| try encode(w, Field, @field(value, name));
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("untagged union in a cache: " ++ @typeName(T));
            try w.writeInt(u32, @backingInt(value), .little);
            switch (value) {
                inline else => |payload, tag| try encode(w, @FieldType(T, @tagName(tag)), payload),
            }
        },
        else => @compileError("no cache encoding for " ++ @typeName(T)),
    }
}

fn isEnumMap(comptime T: type) bool {
    return @hasDecl(T, "Key") and @hasDecl(T, "Value") and @hasField(T, "bits") and @hasField(T, "values");
}

fn Aligned(comptime T: type) type {
    return std.math.ByteAlignedInt(T);
}

fn fixedWidth(comptime T: type) void {
    @setEvalBranchQuota(4_000_000);
    switch (@typeInfo(T)) {
        .int => if (T == usize or T == isize) @compileError("a cache field cannot have the target's pointer width: " ++ @typeName(T)),
        .@"enum" => |e| fixedWidth(e.tag_type),
        .optional => |o| fixedWidth(o.child),
        .array => |a| fixedWidth(a.child),
        .pointer => |p| fixedWidth(p.child),
        .@"struct" => |s| {
            if (isEnumMap(T)) {
                fixedWidth(T.Key);
                fixedWidth(T.Value);
            } else {
                if (@hasDecl(T, "Indexer")) fixedWidth(T.Key);
                if (s.layout == .@"packed") fixedWidth(s.backing_integer.?);
                for (s.field_types) |Field| fixedWidth(Field);
            }
        },
        .@"union" => |u| {
            if (u.tag_type) |Tag| fixedWidth(Tag);
            for (u.field_types) |Field| fixedWidth(Field);
        },
        else => {},
    }
}

fn Bits(comptime F: type) type {
    return @Int(.unsigned, @bitSizeOf(F));
}
