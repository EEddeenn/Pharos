const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const bcnav = @import("bcnav.zig");
const content = @import("bcnav3/content.zig");
const b2b = @import("b2b.zig");

const Error = field.Error;
pub const frame_ms = 1000;
const messages_per_week = 604_800;
pub const bits_per_frame = b2b.bits_per_frame;
pub const Frame = b2b.Frame;
const Message = b2b.Message;
const Type = content.Type;
const order = [3]Type{ .ephemeris, .clock, .almanac };

pub const Set = struct {
    data: bcnav.Data,

    pub const Inputs = bcnav.Inputs;

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.data.build(.bcnav3, in);
        try set.validate();
    }

    fn validate(self: *const Set) Error!void {
        const data = &self.data;
        var first: ?u8 = null;
        for (&data.sv, 1..) |*entry, number| {
            const prn: u8 = @intCast(number);
            if (entry.* == null) continue;
            if (first == null) first = prn;
            if (data.eop != null and data.utc != null) _ = try messageBits(self, prn, .{ .kind = .clock, .sow = 0, .wn = 0, .prns = @splat(0) });
        }
        const prn = first orelse return;
        for (0..3) |target| _ = try messageBits(self, prn, .{ .kind = .almanac, .sow = 0, .wn = 0, .prns = @splat(0), .bgto = @intCast(target) });
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.data.hasRecord(prn) and self.data.eop != null and self.data.utc != null;
    }
};

const Slot = struct { kind: Type, sow: u20, wn: u13, prns: [6]u7, bgto: u2 = 0 };

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

pub fn setCycle(_: u8, index: i64) i64 {
    return @divFloor(index, order.len);
}

fn almanacPrns(sow: u20) [6]u7 {
    var prns: [6]u7 = undefined;
    prns[0] = @intCast((sow / 3) % 63 + 1);
    for (1..6) |k| prns[k] = @intCast((5 * @as(u32, sow) + k - 1) % 63 + 1);
    return prns;
}

fn messageBits(set: *const Set, prn: u8, s: Slot) Error!Message {
    const data = &set.data;
    var in: content.Input = .{
        .sv = data.sv[prn - 1].?,
        .bdgim = data.bdgim,
        .utc = data.utc,
        .eop = data.eop,
        .reference = data.almanac_reference,
        .alm = undefined,
        .bgto = data.bgto(s.bgto),
    };
    for (&in.alm, s.prns) |*packet, number| packet.* = data.packet(number);
    return content.encode(&in, s.kind, .{ .sow = s.sow, .wn = s.wn });
}

pub fn requireData(set: *const Set, prn: u8) error{ MissingEarthOrientation, MissingUtcParameters }!void {
    if (!set.data.hasRecord(prn) or set.hasRecord(prn)) return;
    if (set.data.eop == null) return error.MissingEarthOrientation;
    return error.MissingUtcParameters;
}

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const m = messageBits(set, prn, slot(index)) catch unreachable;
    return b2b.encodeFrame(&m, prn);
}
