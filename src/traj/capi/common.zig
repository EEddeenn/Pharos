const capi = @import("shared").capi;

pub const allocator = capi.allocator;
pub const ErrorBuffer = capi.ErrorBuffer;

pub const abi_version: u32 = 0x0001_0000;

pub const Status = capi.Status(&.{"input"});

pub threadlocal var thread_error: ErrorBuffer = .{};

comptime {
    capi.exports("pharos_traj", @This());
}

pub fn nomem(err: *ErrorBuffer) Status {
    return capi.nomem(Status, err);
}
