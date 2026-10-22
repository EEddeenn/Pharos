const c_allocator = @import("interface/c/allocator");
const buffers = @import("interface/c/buffers");
const status = @import("interface/c/status");

const current_abi_version: u32 = 0x0001_0000;

/// The product name is part of this type's identity, including its thread-local error slot.
pub fn Context(comptime product_prefix: []const u8, comptime status_names: []const [:0]const u8) type {
    return struct {
        pub const prefix = product_prefix;
        pub const abi_version = current_abi_version;
        pub const allocator = c_allocator.allocator;
        pub const ErrorBuffer = buffers.ErrorBuffer;
        pub const Status = status.Status(status_names);

        pub threadlocal var thread_error: ErrorBuffer = .{};

        pub fn nomem(err: *ErrorBuffer) Status {
            return status.nomem(Status, err);
        }
    };
}
