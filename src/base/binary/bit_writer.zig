const std = @import("std");

const mask = @import("base/binary/scaling").mask;

pub const Error = error{ BufferFull, FieldOverflow };

pub const BitWriter = struct {
    words: []u32,
    pos: usize = 0,

    pub fn init(words: []u32) BitWriter {
        @memset(words, 0);
        return .{ .words = words };
    }

    pub fn bitsWritten(self: BitWriter) usize {
        return self.pos;
    }

    pub fn writeBits(self: *BitWriter, comptime width: u7, value: anytype) void {
        comptime checkWidth(width);
        const V = @TypeOf(value);
        const raw: u64 = switch (@typeInfo(V)) {
            .comptime_int => comptime coerceComptime(width, value),
            .int => |int_info| blk: {
                if (int_info.bits != width) {
                    @compileError(std.fmt.comptimePrint(
                        "field width {d} does not match value type {s}",
                        .{ width, @typeName(V) },
                    ));
                }
                if (int_info.signedness == .signed) {
                    const U = @Int(.unsigned, width);
                    break :blk @as(U, @bitCast(value));
                }
                break :blk value;
            },
            .bool => blk: {
                if (width != 1) @compileError("bool fields must have width 1");
                break :blk @intFromBool(value);
            },
            else => @compileError("writeBits expects an exact-width integer, bool or comptime_int"),
        };
        self.writeRaw(width, raw);
    }

    pub fn skip(self: *BitWriter, count: usize) void {
        std.debug.assert(self.pos + count <= self.capacityBits());
        self.pos += count;
    }

    pub fn writeAlternating(self: *BitWriter, count: usize) void {
        for (0..count) |i| self.writeBits(1, i % 2 == 0);
    }

    fn capacityBits(self: BitWriter) usize {
        return self.words.len * 32;
    }

    fn coerceComptime(comptime width: u7, comptime value: comptime_int) u64 {
        const U = @Int(.unsigned, width);
        if (value < 0) {
            const S = @Int(.signed, width);
            const signed: S = value;
            return @as(U, @bitCast(signed));
        }
        const unsigned: U = value;
        return unsigned;
    }

    fn writeRaw(self: *BitWriter, width: u7, value: u64) void {
        var remaining: u7 = width;
        while (remaining > 0) {
            const word_index = self.pos / 32;
            const bit_in_word: u7 = @intCast(self.pos % 32);
            const space: u7 = 32 - bit_in_word;
            const take: u7 = @min(space, remaining);
            const shift_out: u6 = @intCast(remaining - take);
            const chunk: u32 = @intCast((value >> shift_out) & mask(take));
            const shift_in: u5 = @intCast(space - take);
            self.words[word_index] |= chunk << shift_in;
            self.pos += take;
            remaining -= take;
        }
    }
};

pub const BoundedWriter = struct {
    bits: BitWriter,

    pub fn init(words: []u32) BoundedWriter {
        return .{ .bits = .init(words) };
    }

    pub fn bitsWritten(self: BoundedWriter) usize {
        return self.bits.pos;
    }

    pub fn writeBits(self: *BoundedWriter, comptime width: u7, value: anytype) error{BufferFull}!void {
        try self.room(width);
        self.bits.writeBits(width, value);
    }

    pub fn writeUnsigned(self: *BoundedWriter, comptime width: u7, value: u64) Error!void {
        comptime checkWidth(width);
        if (comptime width < 64) {
            if (value >> width != 0) return error.FieldOverflow;
        }
        try self.room(width);
        self.bits.writeRaw(width, value);
    }

    fn room(self: BoundedWriter, count: usize) error{BufferFull}!void {
        if (self.bits.pos + count > self.bits.capacityBits()) return error.BufferFull;
    }
};

pub const BitReader = struct {
    words: []const u32,
    pos: usize = 0,

    pub fn readBits(self: *BitReader, comptime T: type) T {
        const int_info = @typeInfo(T).int;
        const width: u7 = int_info.bits;
        comptime {
            if (width < 1 or width > 64) @compileError("readBits supports 1..64-bit integers");
        }
        var raw: u64 = 0;
        var remaining: u7 = width;
        while (remaining > 0) {
            const word_index = self.pos / 32;
            const bit_in_word: u7 = @intCast(self.pos % 32);
            const space: u7 = 32 - bit_in_word;
            const take: u7 = @min(space, remaining);
            const shift_out: u5 = @intCast(space - take);
            const chunk: u64 = (self.words[word_index] >> shift_out) & mask(take);
            raw = (raw << @intCast(take)) | chunk;
            self.pos += take;
            remaining -= take;
        }
        const U = @Int(.unsigned, width);
        const unsigned: U = @intCast(raw);
        return if (int_info.signedness == .signed) @bitCast(unsigned) else unsigned;
    }
};

pub fn bitAt(words: []const u32, index: usize) u1 {
    const shift: u5 = @intCast(31 - (index % 32));
    return @truncate(words[index / 32] >> shift);
}

fn checkWidth(comptime width: u7) void {
    if (width < 1 or width > 64) @compileError("bit field width must be within 1..64");
}
