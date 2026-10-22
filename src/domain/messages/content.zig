const lnav_content = @import("domain/messages/gps/lnav/content");
const inav_content = @import("domain/messages/galileo/inav/content");
const fnav_content = @import("domain/messages/galileo/fnav/content");
const d1d2_content = @import("domain/messages/bds/d1d2/content");
const bcnav_content = @import("domain/messages/bds/bcnav/content");
const gnav_content = @import("domain/messages/glonass/gnav/content");
const gnss_types = @import("domain/gnss_types");
const cnvx = @import("domain/messages/gps/cnav_common/content");
const NavFamily = gnss_types.NavFamily;
const Unfit = @import("domain/messages/carriage").Unfit;

/// What a family carries for a satellite on a leg, made by the family's `prepare`. The service families
/// carry none.
pub const Content = union(NavFamily) {
    lnav: lnav_content.Content,
    cnav: cnvx.Content,
    cnav2: cnvx.Content,
    inav: inav_content.Content,
    fnav: fnav_content.Content,
    cnav_has: void,
    d1d2: d1d2_content.Content,
    bcnav1: bcnav_content.Content,
    bcnav2: bcnav_content.Content,
    bcnav3: bcnav_content.Content,
    ppp_b2b: void,
    gnav: gnav_content.Content,

    pub fn unfit(self: *const Content) ?Unfit {
        return switch (self.*) {
            .cnav_has, .ppp_b2b => null,
            inline else => |c| switch (c) {
                .carried => null,
                .unfit => |u| u,
            },
        };
    }
};

/// First-preparation choices paired with the family's source facts in the cache.
pub const Choice = union(NavFamily) {
    lnav: lnav_content.Choice,
    cnav: cnvx.Choice,
    cnav2: cnvx.Choice,
    inav: inav_content.Choice,
    fnav: fnav_content.Choice,
    cnav_has: void,
    d1d2: d1d2_content.Choice,
    bcnav1: bcnav_content.Choice,
    bcnav2: bcnav_content.Choice,
    bcnav3: bcnav_content.Choice,
    ppp_b2b: void,
    gnav: gnav_content.Choice,
};
