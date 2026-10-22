const gnss_types = @import("domain/gnss_types");
const message_content = @import("domain/messages/content");
const lnav_message = @import("domain/messages/gps/lnav/set");
const cnav_message = @import("domain/messages/gps/cnav/set");
const cnav2_message = @import("domain/messages/gps/cnav2/set");
const cnav_common = @import("domain/messages/gps/cnav_common/set");
const differential = @import("domain/messages/gps/differential");
const inav_message = @import("domain/messages/galileo/inav/set");
const fnav_message = @import("domain/messages/galileo/fnav/set");
const d1d2_message = @import("domain/messages/bds/d1d2/set");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const bcnav_message = @import("domain/messages/bds/bcnav/set");
const gnav_message = @import("domain/messages/glonass/gnav/set");

const GpsTime = @import("domain/time/gps").GpsTime;
const FlightPlan = @import("simulation/model/flight_plan").FlightPlan;
const PreparedMessages = @import("simulation/model/prepared_messages").PreparedMessages;

pub const Inputs = struct { flight_plan: *const FlightPlan, messages: *const PreparedMessages };

pub fn lnav(input: Inputs, t: GpsTime) lnav_message.Set.Inputs {
    var out: lnav_message.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = &input.messages.almanacs.lnav,
        .system = &input.messages.systems.at(.gps, t).?.lnav,
        .publications = input.messages.publications.gps,
    };
    contents(input.flight_plan, .lnav, t, &out.eph);
    return out;
}

pub fn cnav(input: Inputs, corrections: ?differential.Source, t: GpsTime) cnav_message.Set.Inputs {
    return .{ .navigation = cnavNavigation(input, .cnav, t), .publications = input.messages.publications.gps, .dc = corrections };
}

pub fn cnav2(input: Inputs, corrections: ?differential.Source, t: GpsTime) cnav2_message.Set.Inputs {
    return .{
        .navigation = cnavNavigation(input, .cnav2, t),
        .publications = input.messages.publications.gps,
        .configuration = &input.messages.publications.cnav2_configuration.?,
        .dc = corrections,
    };
}

pub fn inav(input: Inputs, t: GpsTime) inav_message.Set.Inputs {
    var out: inav_message.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = &input.messages.almanacs.galileo,
        .system = input.messages.systems.at(.gal, t).?,
        .publications = input.messages.publications.inav,
    };
    contents(input.flight_plan, .inav, t, &out.eph);
    return out;
}

pub fn fnav(input: Inputs, t: GpsTime) fnav_message.Set.Inputs {
    var out: fnav_message.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = &input.messages.almanacs.galileo,
        .system = input.messages.systems.at(.gal, t).?,
    };
    contents(input.flight_plan, .fnav, t, &out.eph);
    return out;
}

pub fn d1d2(input: Inputs, supplier: ?augmentation.Source, t: GpsTime) d1d2_message.Set.Inputs {
    const system = input.messages.systems.at(.bds, t).?;
    var out: d1d2_message.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = &input.messages.almanacs.d1d2,
        .system = if (system.d1d2) |*value| value else null,
        .publications = input.messages.publications.d2,
        .service = supplier,
    };
    contents(input.flight_plan, .d1d2, t, &out.eph);
    return out;
}

pub fn bcnav(input: Inputs, comptime family: gnss_types.NavFamily, t: GpsTime) bcnav_message.Set.Inputs {
    var out: bcnav_message.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = &input.messages.almanacs.bcnav,
        .system = &input.messages.systems.at(.bds, t).?.bcnav,
    };
    contents(input.flight_plan, family, t, &out.eph);
    return out;
}

pub fn gnav(input: Inputs, t: GpsTime) gnav_message.Set.Inputs {
    const system = input.messages.systems.at(.glo, t).?;
    var out: gnav_message.Set.Inputs = .{
        .eph = @splat(null),
        .almanacs = &input.messages.almanacs.gnav,
        .system = if (system.*) |*value| value else null,
    };
    contents(input.flight_plan, .gnav, t, &out.eph);
    return out;
}

fn contents(flight_plan: *const FlightPlan, comptime family: gnss_types.NavFamily, t: GpsTime, out: []?*const @FieldType(message_content.Content, @tagName(family))) void {
    for (out, 0..) |*slot, i| {
        const content = flight_plan.contentAt(gnss_types.SatId.at(family.system(), i), family, t) orelse continue;
        slot.* = &@field(content, @tagName(family));
    }
}

fn cnavNavigation(input: Inputs, comptime family: gnss_types.NavFamily, t: GpsTime) cnav_common.View {
    var out: cnav_common.View = .{
        .sv = @splat(null),
        .almanacs = &input.messages.almanacs.cnav,
        .system = &input.messages.systems.at(.gps, t).?.cnav,
    };
    contents(input.flight_plan, family, t, &out.sv);
    return out;
}
