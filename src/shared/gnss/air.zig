const std = @import("std");
const types = @import("../core.zig").types;
const health = @import("health.zig");

/// On the air, or the first reason a signal is not: the leg's record's reasons come before the allocation's, so that
/// what the record says of a signal its satellite does not transmit stays known.
pub const Status = enum { on_air, no_group_delay, dead, not_allocated };

pub const Origin = enum { broadcast, convention, assumed };

/// A signal's answer on a leg: one row per signal of the satellite's system, at its `spec.slot`.
pub const Row = struct {
    status: Status,
    health: health.Status,
    delay_s: std.EnumArray(types.Component, f64),
    origin: Origin,

    /// The data delay the records give, null where it is assumed.
    pub fn given(self: Row) ?f64 {
        return if (self.origin == .assumed) null else self.delay_s.get(.data);
    }
};
