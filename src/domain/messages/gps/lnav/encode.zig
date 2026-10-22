const publications = @import("domain/messages/gps/cnav2/publications");
const lnav_set = @import("domain/messages/gps/lnav/set");
const time = @import("domain/time/gps");
const records = @import("domain/navigation/records");
const bit_writer = @import("base/binary/bit_writer");
const field = @import("base/binary/field");
const frame = @import("base/binary/bits");
const fields = @import("domain/messages/gps/lnav/fields");
const messages = @import("domain/messages/gps/publication");
const text = @import("domain/messages/gps/text");
const word = @import("domain/messages/gps/lnav/word");
const Set = lnav_set.Set;
const as_flag = lnav_set.as_flag;
const Parameters = @import("domain/messages/gps/lnav/content").Parameters;
const Alm = records.KeplerAlmanac;
const Error = field.Error;
const frames_per_week = 100_800;
const data_bits_per_subframe = 240;
const subframes_per_superframe = 125;
const fill_first_bit = 60;
const fill_end_bit = 298;

pub const frame_ms = 6000;
pub const bits_per_frame = 300;
pub const Frame = frame.Bits(bits_per_frame);
const Slot = struct {
    subframe: u3,
    page: u5,
    tow_next: u17,
    wn: u10,
};

pub fn buildFrame(set: *const Set, prn: u8, index: i64) ?Frame {
    const eph = if (set.eph[prn - 1]) |e| e else return null;
    var bits: frame.Bits(data_bits_per_subframe) = .{};
    var w = bits.writer();
    const s = slot(index);
    const content = contentAt(set, index);
    encodeContent(set, eph, prn, index, content, &w) catch unreachable;
    var source: [10]u24 = @splat(0);
    for (0..data_bits_per_subframe) |i| source[i / 24] = (source[i / 24] << 1) | bits.get(i);
    var out = Frame.fromWords(30, 10, word.encodeSubframe(source));
    const missing = switch (s.page) {
        16 => textOf(content) == null,
        17 => set.system.page18 == null,
        else => false,
    };
    if (s.subframe == 4 and missing) {
        var i: usize = fill_first_bit;
        while (i < fill_end_bit) : (i += 2) {
            out.set(i, 1);
            out.set(i + 1, 0);
        }
        out.set(fill_end_bit, 0);
        out.set(fill_end_bit + 1, 0);
    }
    return out;
}

fn contentAt(self: *const Set, index: i64) ?*const messages.Declaration {
    const publication = publications.PreparedPublication.at(self.publications, .{ .ms = index * frame_ms }) orelse return null;
    return publication.content.declaration;
}

fn encodeContent(self: *const Set, eph: *const Parameters, prn: u8, index: i64, content: ?*const messages.Declaration, w: *bit_writer.BitWriter) Error!void {
    const s = slot(index);
    var ctx = fields.Ctx{ .wn = s.wn, .tow_next = s.tow_next, .subframe = s.subframe };
    if (content) |c| {
        if (c.integrity) |d| {
            ctx.isf = d.isf;
            ctx.alert = @intFromBool(d.alerts(prn));
        }
    }
    try field.encode(field.NoSource, &fields.tlm, &field.no_source, ctx, w);
    try field.encode(field.NoSource, &fields.how, &field.no_source, ctx, w);
    switch (s.subframe) {
        1 => try field.encode(Parameters, &fields.sf1, eph, ctx, w),
        2 => try field.encode(Parameters, &fields.sf2, eph, ctx, w),
        3 => try field.encode(Parameters, &fields.sf3, eph, ctx, w),
        4 => try encodeSubframe4(self, index, content, ctx, w),
        else => try encodeSubframe5(self, s.page, ctx, w),
    }
}

fn encodeSubframe4(self: *const Set, index: i64, content: ?*const messages.Declaration, ctx: fields.Ctx, w: *bit_writer.BitWriter) Error!void {
    const page = slot(index).page;
    const id = fields.sf4_page_ids[page];
    switch (page) {
        1, 2, 3, 4, 6, 7, 8, 9 => try almanacPage(self, id, ctx, w),
        12 => try field.encode(field.NoSource, &fields.page13, &field.no_source, ctx, w),
        16 => if (textOf(content)) |t| {
            const p: fields.Page17 = .{ .characters = text.page(t, 22, @divFloor(index, subframes_per_superframe)).characters };
            try field.encode(fields.Page17, &fields.page17, &p, ctx, w);
        },
        17 => if (self.system.page18) |*p| field.writeDecoded(fields.Page18, &fields.page18, p.*, w),
        24 => {
            var health = self.almanacs.health;
            if (content) |c| {
                if (c.configuration) |codes| {
                    for (&health.as_config, codes[0..32]) |*term, code| term.* = as_flag | @as(u4, code);
                }
            }
            try field.encode(fields.Health, &fields.sf4_page25, &health, ctx, w);
        },
        else => try filler(id, ctx, w),
    }
}

fn textOf(content: ?*const messages.Declaration) ?[]const u8 {
    return (content orelse return null).text;
}

fn encodeSubframe5(self: *const Set, page: u5, ctx: fields.Ctx, w: *bit_writer.BitWriter) Error!void {
    if (page == 24) return field.encode(fields.Health, &fields.sf5_page25, &self.almanacs.health, ctx, w);
    try almanacPage(self, @as(u6, page) + 1, ctx, w);
}

fn almanacPage(self: *const Set, sv: u6, ctx: fields.Ctx, w: *bit_writer.BitWriter) Error!void {
    if (self.almanacs.entries[sv - 1]) |a| return field.encode(Alm, &fields.almanac_page, a, ctx, w);
    try filler(0, ctx, w);
}

fn filler(id: u6, ctx: fields.Ctx, w: *bit_writer.BitWriter) Error!void {
    var page_ctx = ctx;
    page_ctx.page_sv_id = id;
    try field.encode(field.NoSource, &fields.filler_page, &field.no_source, page_ctx, w);
}

fn slot(index: i64) Slot {
    const in_week = @mod(index, frames_per_week);
    return .{
        .subframe = @intCast(@mod(in_week, 5) + 1),
        .page = @intCast(@mod(@divFloor(in_week, 5), 25)),
        .tow_next = @intCast(@mod(in_week + 1, frames_per_week)),
        .wn = @intCast(@mod(time.weekOfIndex(index, frames_per_week, .gps), time.week_modulus_10)),
    };
}
