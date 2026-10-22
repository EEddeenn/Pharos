const content = @import("domain/messages/galileo/fnav/content");
const almanac = @import("domain/messages/galileo/fields/almanac");
const system = @import("domain/messages/galileo/system");
pub const Set = struct {
    sv: [36]?*const content.Parameters,
    almanacs: *const almanac.Almanacs,
    system: *const system.System,

    pub const Inputs = struct {
        eph: [36]?*const content.Content,
        almanacs: *const almanac.Almanacs,
        system: *const system.System,
    };

    pub fn init(input: Inputs) Set {
        var out: Set = .{ .sv = @splat(null), .almanacs = input.almanacs, .system = input.system };
        for (input.eph, &out.sv) |entry, *slot| slot.* = if (entry) |c| c.value() else null;
        return out;
    }
};
