const time = @import("domain/time/gps");
const field = @import("base/binary/field");
const publication = @import("domain/messages/publication");
const crc32q = @import("base/binary/crc").crc32q;
const Word = @import("domain/messages/galileo/inav/page").Word;
pub const tow_step_ms = 1_800_000;
pub const Ism = union(enum) {
    test_message: u87,
    no_data,
    horizontal: Sl3,
};

pub const Publication = publication.Publication(Ism);
pub const Content = struct {
    declaration: *const Ism,
    word: Word,
    validity: ?struct { from: time.GpsTime, until: time.GpsTime } = null,

    pub fn init(src: *const Ism) Content {
        return .{
            .declaration = src,
            .word = encode(src),
            .validity = if (src.* == .horizontal) .{
                .from = src.horizontal.reference,
                .until = src.horizontal.reference.addMs(validity_hours[src.horizontal.t_validity] * time.ms_per_hour),
            } else null,
        };
    }

    pub fn available(self: *const Content, t: time.GpsTime) bool {
        const interval = self.validity orelse return true;
        return !t.lessThan(interval.from) and t.lessThan(interval.until);
    }
};

pub const PreparedPublication = publication.Publication(Content);
pub const Sl3 = struct {
    reference: time.GpsTime,
    mask_msb: bool,
    mask: u32,
    p_const: u4,
    p_sat: u4,
    ura: u4,
    ure: u4,
    b_nom: u4,
    t_validity: u4,
};

const validity_hours = [16]i64{ 1, 2, 3, 4, 6, 8, 12, 18, 24, 36, 48, 72, 120, 168, 720, 1440 };
const F = field.Field(Sl3);

fn encode(src: *const Ism) Word {
    var out: Word = .{};
    var w = out.writer();
    w.writeBits(6, 22);
    switch (src.*) {
        .test_message => |content| {
            w.writeBits(3, 0);
            w.writeBits(23, @as(u23, @truncate(content >> 64)));
            w.writeBits(64, @as(u64, @truncate(content)));
        },
        .no_data => {
            w.writeBits(3, 1);
            w.writeBits(3, 0);
            w.skip(84);
        },
        .horizontal => |*data| {
            var codes = field.project(Sl3, &horizontal, data);
            codes.wn = @intCast(@mod(data.reference.week() - time.gal_week_offset, time.week_modulus_12));
            codes.tow = @intCast(@divExact(data.reference.msOfWeek(), tow_step_ms));
            field.writeDecoded(Sl3, &horizontal, codes, &w);
        },
    }
    w.writeBits(32, crc32q.ofBits(&out.words, 96));
    return out;
}
const horizontal = [_]F{
    .{ .name = "gnss_id", .width = 3, .src = .{ .constant = 1 } },
    .{ .name = "sl_id", .width = 3, .src = .{ .constant = 2 } },
    .{ .name = "wn", .width = 12, .src = .{ .ctx = "wn" } },
    .{ .name = "tow", .width = 9, .src = .{ .ctx = "tow" } },
    .{ .name = "mask_msb", .width = 1, .src = .{ .field = "mask_msb" } },
    .{ .name = "mask", .width = 32, .src = .{ .field = "mask" } },
    .{ .name = "p_const", .width = 4, .src = .{ .field = "p_const" } },
    .{ .name = "p_sat", .width = 4, .src = .{ .field = "p_sat" } },
    .{ .name = "ura", .width = 4, .src = .{ .field = "ura" } },
    .{ .name = "ure", .width = 4, .src = .{ .field = "ure" } },
    .{ .name = "b_nom", .width = 4, .src = .{ .field = "b_nom" } },
    .{ .name = "t_validity", .width = 4, .src = .{ .field = "t_validity" } },
    .{ .name = "spare", .width = 6, .src = .reserved },
};
