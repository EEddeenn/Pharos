const content = @import("domain/messages/galileo/inav/content");
const almanac = @import("domain/messages/galileo/fields/almanac");
const system = @import("domain/messages/galileo/system");
const ism = @import("domain/messages/galileo/inav/ism");
pub const Set = struct {
    sv: [36]?*const content.Prepared,
    almanacs: *const almanac.Almanacs,
    system: *const system.System,
    publications: []const ism.PreparedPublication = &.{},

    pub const Inputs = struct {
        eph: [36]?*const content.Content,
        almanacs: *const almanac.Almanacs,
        system: *const system.System,
        publications: []const ism.PreparedPublication = &.{},
    };

    pub fn init(input: Inputs) Set {
        var out: Set = .{ .sv = @splat(null), .almanacs = input.almanacs, .system = input.system, .publications = input.publications };
        for (input.eph, &out.sv) |entry, *slot| slot.* = if (entry) |c| c.value() else null;
        return out;
    }
};
