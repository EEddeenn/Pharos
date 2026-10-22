const std = @import("std");
const prepared_bundle = @import("phb/prepared");
const c_phb = @import("interface/c/phb");
const common = @import("products/obs/c_api/context").Context;
const allocator = common.allocator;
const Status = common.Status;

pub const Handle = struct {
    arena: std.heap.ArenaAllocator,
    b: prepared_bundle.PreparedBundle,
    references: std.atomic.Value(usize) = .init(1),

    pub fn retain(self: *Handle) void {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
    }

    pub fn release(self: *Handle) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub fn pharos_obs_source_create(data: ?[*]const u8, len: usize, out: ?*?*Handle) callconv(.c) Status {
    common.thread_error.clear();
    const dst = out orelse return .arg;
    dst.* = null;
    const bytes = (data orelse return .arg)[0..len];
    const h = allocator.create(Handle) catch return common.nomem(&common.thread_error);
    h.* = .{ .arena = .init(allocator), .b = undefined };
    const status = c_phb.readPreparedBundle(Status, h.arena.allocator(), bytes, &common.thread_error, &h.b);
    if (status != .ok) {
        h.release();
        return status;
    }
    dst.* = h;
    return .ok;
}

pub fn pharos_obs_source_destroy(source: ?*Handle) callconv(.c) void {
    if (source) |h| h.release();
}
