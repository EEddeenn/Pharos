const parameters = @import("domain/navigation/orbit/parameters");
const records = @import("domain/navigation/records");
const nav_reference = @import("domain/navigation/reference");
const fields = @import("domain/messages/gps/lnav/fields");

const carriage = @import("domain/messages/carriage");
pub const Parameters = struct {
    eph: parameters.Parameters,
    iode: u16,
    iodc: u16,
    l2_codes: u2,
    ura_index: u4,
    health: u6,
    l2p_data: bool,
    fit_interval: bool,
    tgd: f64,

    fn of(e: nav_reference.Kepler, tgd: ?f64) Parameters {
        const x = (e.attribute(.lnav) orelse unreachable).lnav;
        return .{
            .eph = e.record.parameters(),
            .iode = e.record.iode,
            .iodc = e.record.iodc,
            .l2_codes = x.l2_codes,
            .ura_index = x.ura_index,
            .health = x.health,
            .l2p_data = x.l2p_data,
            .fit_interval = x.fit_interval,
            .tgd = tgd orelse 0,
        };
    }
};
pub const Content = carriage.Carriage(Parameters);
pub const Choice = carriage.Choice;
pub const Preparation = struct { choice: Choice, content: Content };

pub const toe_step_ms = 16_000;

pub fn misfit(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    return fields.misfit(&Parameters.of(.raw(e), e.group_delay.get(.tgd_l1ca)));
}

/// LNAV's broadcast parameters for a leg, with its T_GD, or the first field that does not fit.
pub fn prepare(e: nav_reference.Kepler) Preparation {
    const choice: Choice = if (e.record.source() != .lnav) .{ .unfit = .record } else blk: {
        const out = Parameters.of(e, e.delay(.l1ca, .data));
        if (fields.misfit(&out)) |name| break :blk .{ .unfit = .{ .field = name } };
        return .{ .choice = .carried, .content = .{ .carried = out } };
    };
    return .{ .choice = choice, .content = .{ .unfit = choice.unfit } };
}

pub fn project(e: nav_reference.Kepler, choice: Choice) Content {
    return switch (choice) {
        .carried => .{ .carried = Parameters.of(e, e.delay(.l1ca, .data)) },
        .unfit => |why| .{ .unfit = why },
    };
}
