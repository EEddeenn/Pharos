const capi = @import("shared").capi;

pub const allocator = capi.allocator;
pub const ErrorBuffer = capi.ErrorBuffer;

pub const abi_version: u32 = 0x0001_0000;

pub const Status = capi.Status(&.{ "bundle", "nav" });

pub const Bytes = extern struct {
    data: ?[*]const u8 = null,
    len: usize = 0,
};

pub threadlocal var thread_error: ErrorBuffer = .{};

comptime {
    capi.exports("pharos_obs", @This());
}

pub fn nomem(err: *ErrorBuffer) Status {
    return capi.nomem(Status, err);
}
