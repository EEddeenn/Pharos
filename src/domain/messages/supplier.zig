pub fn Supplier(comptime Key: type, comptime Value: type) type {
    return struct {
        ptr: *const anyopaque,
        readFn: *const fn (*const anyopaque, Key) ?Value,

        pub fn read(self: @This(), key: Key) ?Value {
            return self.readFn(self.ptr, key);
        }

        pub fn of(comptime T: type, source: *const T) @This() {
            return .{ .ptr = source, .readFn = struct {
                fn read(ptr: *const anyopaque, key: Key) ?Value {
                    const instance: *const T = @ptrCast(@alignCast(ptr));
                    return instance.read(key);
                }
            }.read };
        }
    };
}
