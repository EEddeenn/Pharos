pub fn Ring(comptime T: type, comptime len: usize) type {
    return struct {
        slots: [len]?Slot = @splat(null),

        const Slot = struct { index: i64, value: T };

        pub fn put(self: *@This(), index: i64, value: T) void {
            self.slots[@intCast(@mod(index, len))] = .{ .index = index, .value = value };
        }

        pub fn get(self: *const @This(), index: i64) ?T {
            const slot = self.slots[@intCast(@mod(index, len))] orelse return null;
            return if (slot.index == index) slot.value else null;
        }
    };
}
