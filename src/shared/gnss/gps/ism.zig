const dictionary = @import("../../core.zig").dictionary;
const time = @import("../../core.zig").time;
const field = @import("../../codec.zig").field;
const bitwriter = @import("../../codec.zig").bitwriter;
const crc32q = @import("../../codec.zig").crc32q;

pub const Constellation = enum(u4) {
    unavailable,
    galileo,
    glonass,
    beidou,
    gps,
    sbas,
    qzss,
    irnss,

    pub const words = dictionary.tagNames(Constellation);

    const Identifiers = struct { first: u32, last: u32 };

    pub fn identifiers(self: Constellation) ?Identifiers {
        return switch (self) {
            .unavailable => null,
            .gps => .{ .first = 1, .last = 63 },
            .galileo => .{ .first = 1, .last = 36 },
            .glonass => .{ .first = 1, .last = 32 },
            .beidou => .{ .first = 1, .last = 37 },
            .sbas => .{ .first = 120, .last = 158 },
            .qzss => .{ .first = 183, .last = 202 },
            .irnss => .{ .first = 1, .last = 7 },
        };
    }

    pub fn bitOf(self: Constellation, id: u32) ?u63 {
        const range = self.identifiers() orelse return null;
        if (id < range.first or id > range.last) return null;
        return @as(u63, 1) << @intCast(62 - (id - range.first));
    }

    fn reservedBits(self: Constellation) u6 {
        const range = self.identifiers() orelse return 0;
        return @intCast(63 - (range.last - range.first + 1));
    }
};
pub const Service = enum(u3) {
    unavailable,
    non_safety,
    horizontal,
    vertical,

    pub const words = dictionary.tagNames(Service);
};

pub const Ism = struct {
    reference: time.GpsTime,
    constellation: Constellation,
    t_correl: u4,
    b_nom: u4,
    gamma_nom: u4,
    r_sat: u4,
    p_const: u4,
    mfd: u4,
    service: Service,
    mask: u63,
};

pub const parameter_bits = 113;

const I = field.Field(Ism);
const rows = [_]I{
    .{ .name = "gnss_id", .width = 4, .src = .{ .ctx = "gnss_id" } },
    .{ .name = "wn", .width = 13, .src = .{ .ctx = "wn" } },
    .{ .name = "tow", .width = 6, .src = .{ .ctx = "tow" } },
    .{ .name = "t_correl", .width = 4, .src = .{ .field = "t_correl" } },
    .{ .name = "b_nom", .width = 4, .src = .{ .field = "b_nom" } },
    .{ .name = "gamma_nom", .width = 4, .src = .{ .field = "gamma_nom" } },
    .{ .name = "r_sat", .width = 4, .src = .{ .field = "r_sat" } },
    .{ .name = "p_const", .width = 4, .src = .{ .field = "p_const" } },
    .{ .name = "mfd", .width = 4, .src = .{ .field = "mfd" } },
    .{ .name = "service", .width = 3, .src = .{ .ctx = "service" } },
    .{ .name = "mask", .width = 63, .src = .{ .field = "mask" } },
};

pub const tow_step_ms = 14_400_000;

pub fn check(src: *const Ism) error{ValueOutOfRange}!void {
    if (src.reference.sub_ms != 0 or @mod(src.reference.ms, tow_step_ms) != 0) return error.ValueOutOfRange;
    if (src.t_correl == 15 or src.r_sat == 15 or src.p_const == 15) return error.ValueOutOfRange;
    if (src.mask & ((@as(u63, 1) << src.constellation.reservedBits()) - 1) != 0) return error.ValueOutOfRange;
}

pub fn encode(src: *const Ism, w: *bitwriter.BitWriter, filler: usize) field.Error!void {
    try field.encode(Ism, &rows, src, .{
        .gnss_id = @intFromEnum(src.constellation),
        .wn = @mod(src.reference.week(), time.week_modulus_13),
        .tow = @divExact(src.reference.msOfWeek(), tow_step_ms),
        .service = @intFromEnum(src.service),
    }, w);
    w.writeAlternating(filler);
}

pub fn crc(words: []const u32, from: usize, to: usize) u32 {
    return crc32q.update(0, words, from, to);
}

comptime {
    if (field.totalWidth(Ism, &rows) != parameter_bits) @compileError("ISM parameter rows");
}
