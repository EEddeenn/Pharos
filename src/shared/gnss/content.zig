const types = @import("../core.zig").types;
const civil = @import("../core.zig").civil;
const records = @import("records.zig");
const cnvx = @import("gps/cnvx.zig");
const lnav = @import("gps/lnav.zig");
const inav = @import("galileo/inav.zig");
const fnav = @import("galileo/fnav.zig");
const d1d2 = @import("bds/d1d2.zig");
const bcnav = @import("bds/bcnav.zig");
const gnav = @import("glonass/gnav.zig");

const NavFamily = types.NavFamily;

/// Why a family cannot carry a leg's reference.
pub const Unfit = union(enum) {
    /// The family carries its own records only, and the leg flies another family's.
    record,
    /// A value falls outside its field in the family's messages: the field's name.
    field: []const u8,
    /// The reference declares no health of the named signals.
    health: []const u8,
    /// No D1/D2 orbit fits the reference over the leg.
    fit,
};

/// A family's answer for a leg: the value its messages broadcast, or why it cannot carry the leg's reference.
pub fn Carriage(comptime T: type) type {
    return union(enum) {
        carried: T,
        unfit: Unfit,

        pub fn value(self: *const @This()) ?*const T {
            return switch (self.*) {
                .carried => |*v| v,
                .unfit => null,
            };
        }
    };
}

/// What a family carries for a satellite on a leg, made by the family's `prepare` in the packer. The service families
/// carry none.
pub const Content = union(NavFamily) {
    lnav: lnav.Content,
    cnav: cnvx.Content,
    cnav2: cnvx.Content,
    inav: inav.Content,
    fnav: fnav.Content,
    cnav_has: void,
    d1d2: d1d2.Content,
    bcnav1: bcnav.Content,
    bcnav2: bcnav.Content,
    bcnav3: bcnav.Content,
    ppp_b2b: void,
    gnav: gnav.Content,

    pub fn unfit(self: *const Content) ?Unfit {
        return switch (self.*) {
            .cnav_has, .ppp_b2b => null,
            inline else => |c| switch (c) {
                .carried => null,
                .unfit => |u| u,
            },
        };
    }

    /// Whether a content of a bundle from outside fits its family's messages, as the family's `prepare` makes it.
    pub fn valid(self: *const Content, sat: types.SatId, leap: civil.Leap) bool {
        return switch (self.*) {
            .cnav_has, .ppp_b2b => false,
            inline else => |*c, family| {
                const v = c.value() orelse return true;
                return switch (family) {
                    .lnav => lnav.valid(v, sat),
                    .cnav, .cnav2 => cnvx.valid(v, sat),
                    .inav => inav.valid(v, sat),
                    .fnav => fnav.valid(v, sat),
                    .d1d2 => v.valid(sat),
                    .bcnav1, .bcnav2, .bcnav3 => bcnav.valid(v, sat),
                    .gnav => gnav.valid(v, sat, leap),
                    .cnav_has, .ppp_b2b => unreachable,
                };
            },
        };
    }
};
