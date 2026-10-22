const std = @import("std");

/// A borrowed byte slice. Its producer defines when the storage is invalidated.
pub const ByteView = extern struct {
    data: ?[*]const u8 = null,
    len: usize = 0,

    pub fn fromSlice(bytes: []const u8) ByteView {
        return .{ .data = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
    }
};

pub const ErrorBuffer = struct {
    buf: [256]u8 = @splat(0),
    len: usize = 0,

    pub fn clear(self: *ErrorBuffer) void {
        self.len = 0;
        self.buf[0] = 0;
    }

    pub fn set(self: *ErrorBuffer, comptime fmt: []const u8, args: anytype) void {
        const content = self.buf[0 .. self.buf.len - 1];
        const text = std.mem.print(content, fmt, args) catch cut: {
            // A text longer than the buffer ends before the character it would cut through.
            var lead: usize = content.len - 1;
            while (lead > 0 and content[lead] & 0xC0 == 0x80) lead -= 1;
            const length = std.unicode.utf8ByteSequenceLength(content[lead]) catch 1;
            break :cut content[0..if (lead + length > content.len) lead else content.len];
        };
        self.len = text.len;
        self.buf[self.len] = 0;
    }

    pub fn cstr(self: *const ErrorBuffer) [*:0]const u8 {
        return self.buf[0..self.len :0];
    }
};

pub const elided_len = 128;

pub fn elide(buffer: *[elided_len]u8, text: []const u8) []const u8 {
    if (text.len <= elided_len) return text;
    const half = (elided_len - 3) / 2;
    // The head ends and the tail begins at a character, not inside one.
    var head: usize = half;
    while (head > 0 and text[head] & 0xC0 == 0x80) head -= 1;
    var tail: usize = text.len - half;
    while (tail < text.len and text[tail] & 0xC0 == 0x80) tail += 1;
    @memcpy(buffer[0..head], text[0..head]);
    @memcpy(buffer[head..][0..3], "...");
    @memcpy(buffer[head + 3 ..][0 .. text.len - tail], text[tail..]);
    return buffer[0 .. head + 3 + text.len - tail];
}
