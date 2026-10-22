const gnss_types = @import("domain/gnss_types");
const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const bit_writer = @import("base/binary/bit_writer");
const glonass_records = @import("domain/navigation/records/glonass");
const fields = @import("domain/messages/glonass/gnav/fields");
const string = @import("domain/messages/glonass/gnav/string");
const Set = @import("domain/messages/glonass/gnav/set").Set;
const Parameters = @import("domain/messages/glonass/gnav/content").Parameters;
const Alm = glonass_records.GlonassAlmanac;
const Error = field.Error;
const strings_per_frame = 15;
const frames_per_day = 2880;
const strings_per_day = strings_per_frame * frames_per_day;
const frames_per_hour = 120;
const slots = gnss_types.System.glo.capacity();

pub const frame_ms = 2000;
pub const bits_per_frame = string.symbols_per_string;
pub const Frame = string.Frame;
const Slot = struct {
    string: u4,
    frame_in_superframe: u3,
    tk_h: u5,
    tk_m: u6,
    tk_half: u1,
};

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    if (!set.hasRecord(prn)) return null;
    const data = encodeData(set, prn, index) catch unreachable;
    return string.encode(string.encodeString(data));
}

fn encodeData(self: *const Set, prn: u8, index: i64) Error!u76 {
    var bits: frame.Bits(fields.data_bits) = .{};
    var w = bits.writer();
    const s = slot(index);
    const prepared = self.eph[prn - 1].?;
    const eph = &prepared.parameters;
    const moscow = fields.moscow(eph, self.system.?.leap);
    const ctx = fields.Ctx{
        .m = s.string,
        .tk_h = s.tk_h,
        .tk_m = s.tk_m,
        .tk_half = s.tk_half,
        .p1 = if (index == prepared.first_string) eph.p1 else 0,
        .p3 = @intFromBool(s.frame_in_superframe < 4),
        .ln = @intFromBool(!eph.health),
        .tb = moscow.tb,
        .p2 = moscow.p2,
        .nt = moscow.nt,
    };
    switch (s.string) {
        1 => try field.encode(Parameters, &fields.string1, eph, ctx, &w),
        2 => try field.encode(Parameters, &fields.string2, eph, ctx, &w),
        3 => try field.encode(Parameters, &fields.string3, eph, ctx, &w),
        4 => try field.encode(Parameters, &fields.string4, eph, ctx, &w),
        5 => {
            var codes = self.system.?.scale;
            codes.ln = ctx.ln;
            field.writeDecoded(fields.TimeScale, &fields.string5, codes, &w);
        },
        else => try encodeAlmanac(self, s, ctx, &w),
    }
    var data: u76 = 0;
    for (0..fields.data_bits) |i| data = (data << 1) | bits.get(i);
    return data;
}

fn encodeAlmanac(self: *const Set, s: Slot, ctx: fields.Ctx, w: *bit_writer.BitWriter) Error!void {
    const pair: u5 = (s.string - 6) / 2;
    const number: u5 = @as(u5, s.frame_in_superframe) * 5 + pair + 1;
    var almanac_ctx = ctx;
    almanac_ctx.slot = number;
    const even = s.string % 2 == 0;

    if (number <= slots) {
        if (self.almanacs.entries[number - 1]) |a| {
            return if (even)
                field.encode(Alm, &fields.almanac_even, a, almanac_ctx, w)
            else
                field.encode(Alm, &fields.almanac_odd, a, almanac_ctx, w);
        }
        if (even) return field.encode(field.NoSource, &fields.empty_even, &field.no_source, almanac_ctx, w);
    }

    if (even) {
        var codes = self.system.?.string14;
        codes.m = almanac_ctx.m;
        field.writeDecoded(fields.String14, &fields.string14, codes, w);
        return;
    }
    try field.encode(field.NoSource, &fields.filler_odd, &field.no_source, almanac_ctx, w);
}

fn slot(index: i64) Slot {
    const in_day = @mod(index, strings_per_day);
    const fr = @divFloor(in_day, strings_per_frame);
    return .{
        .string = @intCast(@mod(in_day, strings_per_frame) + 1),
        .frame_in_superframe = @intCast(@mod(fr, 5)),
        .tk_h = @intCast(@divFloor(fr, frames_per_hour)),
        .tk_m = @intCast(@divFloor(@mod(fr, frames_per_hour), 2)),
        .tk_half = @intCast(@mod(fr, 2)),
    };
}
