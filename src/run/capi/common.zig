const capi = @import("shared").capi;

pub const allocator = capi.allocator;
pub const ErrorBuffer = capi.ErrorBuffer;

pub const abi_version: u32 = 0x0001_0000;

pub const Status = capi.Status(&.{ "bundle", "nav", "io", "busy" });

pub threadlocal var thread_error: ErrorBuffer = .{};

comptime {
    capi.exports("pharos_run", @This());
}

pub fn nomem(err: *ErrorBuffer) Status {
    return capi.nomem(Status, err);
}

pub fn copyOut(text: []const u8, buf: ?[*]u8, cap: usize, len: ?*usize) Status {
    return capi.copyOut(Status, u8, text, buf, cap, len);
}
