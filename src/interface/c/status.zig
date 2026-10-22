const c_buffers = @import("interface/c/buffers");
const ErrorBuffer = c_buffers.ErrorBuffer;

/// Every status of the four libraries at its one number; each library takes the names it returns.
const AnyStatus = enum(c_int) { ok, end, arg, nomem, internal, input, io, bundle, busy };

pub fn Status(comptime own: []const [:0]const u8) type {
    const names = [_][:0]const u8{ "ok", "end", "arg", "nomem", "internal" } ++ own.*;
    var numbers: [names.len]c_int = undefined;
    for (names, &numbers) |name, *number| number.* = @backingInt(@field(AnyStatus, name));
    return @Enum(c_int, .exhaustive, &names, &numbers);
}

pub fn nomem(comptime S: type, err: *ErrorBuffer) S {
    err.set("out of memory", .{});
    return .nomem;
}
