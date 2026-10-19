const field = @import("../../../codec.zig").field;
const frame = @import("../../../codec.zig").frame;
const crc24q = @import("../../../codec.zig").crc24q;
const bcnav = @import("../bcnav.zig");
const tables = @import("tables.zig");
const ephemeris = @import("../ephemeris_fields.zig");
const almanac = @import("../almanac_fields.zig");
const iono = @import("../iono_fields.zig");
const time_parameters = @import("../time_parameters.zig");

const sf2_data_bits = 576;
const sf3_data_bits = 240;

const Sv = bcnav.Sv;
const Sf2 = frame.Bits(600);
const Sf3 = frame.Bits(264);
const Error = field.Error;
pub const Page = union(enum) { p0, p1, p2: [4]u7, p3: u2, p4: u7 };

/// The first of B-CNAV1's fields that the satellite's content fills, beyond its ephemeris, that the content does not fit.
pub fn misfit(sv: *const Sv) ?[:0]const u8 {
    inline for (.{ &tables.sf2_tail, &tables.page0, &tables.page1_header, &tables.page2_header, &tables.page3_header, &tables.page4_header }) |rows| {
        if (field.misfit(Sv, rows, sv)) |name| return name;
    }
    return null;
}

pub const Set = struct {
    data: bcnav.Data,

    pub const Inputs = bcnav.Inputs;

    pub fn build(set: *Set, in: Inputs) Error!void {
        set.data.build(.bcnav1, in);
        try set.validate();
    }

    fn validate(set: *const Set) Error!void {
        var first: ?u8 = null;
        for (&set.data.sv, 1..) |*entry, number| {
            if (entry.* == null) continue;
            const prn: u8 = @intCast(number);
            if (first == null) first = prn;
            _ = try subframe2Bits(set, prn, .{ .wn = 0, .how = 0 });
        }
        const prn = first orelse return;
        _ = try subframe3Bits(set, prn, .p1);
        for (0..3) |target| _ = try subframe3Bits(set, prn, .{ .p3 = @intCast(target) });
    }

    pub fn hasRecord(self: *const Set, prn: u8) bool {
        return self.data.hasRecord(prn);
    }
};

pub fn subframe2Bits(set: *const Set, prn: u8, ctx: tables.Ctx2) Error!Sf2 {
    var out: Sf2 = .{};
    var w = out.writer();
    const sv = &set.data.sv[prn - 1].?;
    try field.encode(tables.Ctx2, &tables.sf2_header, &ctx, .{}, &w);
    try field.encode(ephemeris.Source, &(ephemeris.iodc ++ ephemeris.eph1 ++ ephemeris.eph2 ++ ephemeris.clock), &sv.ephemeris, .{}, &w);
    try field.encode(Sv, &tables.sf2_tail, sv, .{}, &w);
    w.writeBits(24, crc24q.ofBits(&out.words, sf2_data_bits));
    return out;
}

pub fn subframe3Bits(set: *const Set, prn: u8, requested: Page) Error!Sf3 {
    var out: Sf3 = .{};
    var w = out.writer();
    const data = &set.data;
    const sv = &data.sv[prn - 1].?;
    var page = requested;
    if (page == .p3 and data.eop == null) page = .p1;
    if (page == .p1 and data.utc == null) page = .p0;
    switch (page) {
        .p0 => try field.encode(Sv, &tables.page0, sv, .{}, &w),
        .p1 => {
            try field.encode(Sv, &tables.page1_header, sv, .{}, &w);
            try field.encode(iono.Coefficients, &iono.bdgim, &data.bdgim, .{}, &w);
            try field.encode(time_parameters.Utc, &time_parameters.utc, &data.utc.?, .{}, &w);
            try field.encode(field.NoSource, &tables.page1_tail, &field.no_source, .{}, &w);
        },
        .p2 => |prns| {
            try field.encode(Sv, &tables.page2_header, sv, .{}, &w);
            try field.encode(almanac.Reference, &almanac.reference, &data.almanac_reference, .{}, &w);
            for (prns) |p| try field.encode(almanac.Packet, &almanac.reduced, &data.packet(p), .{}, &w);
            try field.encode(field.NoSource, &tables.page2_tail, &field.no_source, .{}, &w);
        },
        .p3 => |target| {
            try field.encode(Sv, &tables.page3_header, sv, .{}, &w);
            try field.encode(time_parameters.Eop, &time_parameters.eop, &data.eop.?, .{}, &w);
            try field.encode(time_parameters.Bgto, &time_parameters.bgto, &data.bgto(target), .{}, &w);
            try field.encode(field.NoSource, &tables.page3_tail, &field.no_source, .{}, &w);
        },
        .p4 => |p| {
            try field.encode(Sv, &tables.page4_header, sv, .{}, &w);
            try field.encode(almanac.Packet, &almanac.midi, &data.packet(p), .{}, &w);
            try field.encode(field.NoSource, &tables.page4_tail, &field.no_source, .{}, &w);
        },
    }
    w.writeBits(24, crc24q.ofBits(&out.words, sf3_data_bits));
    return out;
}
