const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const content = @import("domain/messages/bds/bcnav3/fields");
const b2b = @import("domain/messages/bds/b2b_frame");
const set_model = @import("domain/messages/bds/bcnav3/set");
const Set = set_model.Set;
const Error = field.Error;
const Message = b2b.Message;
const Type = content.Type;
const messages_per_week = 604_800;

pub const frame_ms = 1000;
pub const bits_per_frame = b2b.bits_per_frame;
pub const Frame = b2b.Frame;
const order = [3]Type{ .ephemeris, .clock, .almanac };
const Slot = struct { kind: Type, sow: u20, wn: u13, prns: [6]u7, bgto: u2 = 0 };

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const navigation = if (set.navigation) |*value| value else return null;
    if (navigation.sv[prn - 1] == null) return null;
    const m = messageBits(navigation, prn, slot(index)) catch unreachable;
    return b2b.encodeFrame(&m, prn);
}

pub fn setCycle(_: u8, index: i64) i64 {
    return @divFloor(index, order.len);
}

fn slot(index: i64) Slot {
    const sow: u20 = @intCast(@mod(index, messages_per_week));
    const kind = order[@intCast(@mod(index, 3))];
    const prns: [6]u7 = if (kind == .almanac) almanacPrns(sow) else @splat(0);
    const wn: u13 = @intCast(@mod(time.weekOfIndex(index, messages_per_week, .bds), time.week_modulus_13));
    const bgto: u2 = @intCast(@mod(@divFloor(index, 3), 3));

    return .{
        .kind = kind,
        .sow = sow,
        .wn = wn,
        .prns = prns,
        .bgto = bgto,
    };
}

fn messageBits(set: *const set_model.Navigation, prn: u8, s: Slot) Error!Message {
    const data = set;
    var in: content.Input = .{
        .sv = data.sv[prn - 1].?.*,
        .bdgim = data.system.bdgim,
        .utc = data.utc.*,
        .eop = data.eop.*,
        .reference = data.almanacs.reference,
        .alm = undefined,
        .bgto = data.system.bgto(s.bgto),
    };
    for (&in.alm, s.prns) |*packet, number| packet.* = data.almanacs.packet(number);
    return content.encode(&in, s.kind, .{ .sow = s.sow, .wn = s.wn });
}

fn almanacPrns(sow: u20) [6]u7 {
    var prns: [6]u7 = undefined;
    prns[0] = @intCast((sow / 3) % 63 + 1);
    for (1..6) |k| prns[k] = @intCast((5 * @as(u32, sow) + k - 1) % 63 + 1);
    return prns;
}
