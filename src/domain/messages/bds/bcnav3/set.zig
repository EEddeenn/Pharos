const shared = @import("domain/messages/bds/bcnav/set");
const content = @import("domain/messages/bds/bcnav/content");
const time = @import("domain/messages/bds/fields/time");

pub const Navigation = struct {
    sv: [63]?*const content.Sv,
    almanacs: *const shared.Almanacs,
    system: *const shared.System,
    utc: *const time.UtcCodes,
    eop: *const time.EopCodes,
};

pub const Set = struct {
    navigation: ?Navigation,

    pub const Inputs = shared.Set.Inputs;

    pub fn init(input: Inputs) Set {
        const utc = if (input.system.utc) |*value| value else return .{ .navigation = null };
        const eop = if (input.system.eop) |*value| value else return .{ .navigation = null };
        const view = shared.Set.init(input);
        return .{ .navigation = .{
            .sv = view.sv,
            .almanacs = view.almanacs,
            .system = view.system,
            .utc = utc,
            .eop = eop,
        } };
    }
};
