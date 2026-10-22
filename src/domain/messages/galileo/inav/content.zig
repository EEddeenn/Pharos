const page = @import("domain/messages/galileo/inav/page");
const fec2 = @import("domain/messages/galileo/inav/fec2");
const field = @import("base/binary/field");
const reference = @import("domain/navigation/reference");
const projection = @import("domain/messages/galileo/ephemeris_projection");
const fields = @import("domain/messages/galileo/inav/fields");
const carriage = @import("domain/messages/carriage");
const Word = page.Word;
const OrbitParameters = @import("domain/navigation/orbit/parameters").Parameters;
pub const Parameters = struct {
    eph: OrbitParameters,
    iod_nav: u10,
    sisa_index: u8,
    e1b_hs: u2,
    e5b_hs: u2,
    e1b_dvs: bool,
    e5b_dvs: bool,
    bgd_e1e5a: f64,
    bgd_e1e5b: f64,
};

pub const Prepared = struct { parameters: Parameters, parity: [fec2.parity_len]u8 };
pub const Content = carriage.Carriage(Prepared);
pub const Choice = carriage.Choice;
pub const Preparation = struct { choice: Choice, content: Content };

/// I/NAV's content for a leg: its own reference's parameters and fields, with the leg's BGDs, or the first field it
/// does not fit. I/NAV carries no other family's record.
pub fn prepare(e: reference.Kepler) Preparation {
    if (e.record.source() != .inav) return .{ .choice = .{ .unfit = .record }, .content = .{ .unfit = .record } };
    const out = parametersOf(e);
    if (misfit(&out)) |name| {
        const why: carriage.Unfit = .{ .field = name };
        return .{ .choice = .{ .unfit = why }, .content = .{ .unfit = why } };
    }
    return .{ .choice = .carried, .content = .{ .carried = .{ .parameters = out, .parity = parityOf(&out) } } };
}

pub fn project(e: reference.Kepler, choice: Choice) Content {
    return switch (choice) {
        .carried => blk: {
            const out = parametersOf(e);
            break :blk .{ .carried = .{ .parameters = out, .parity = parityOf(&out) } };
        },
        .unfit => |why| .{ .unfit = why },
    };
}

fn parametersOf(e: reference.Kepler) Parameters {
    const x = e.attribute(.inav).?.inav;
    return .{
        .eph = projection.forSource(e, .inav),
        .iod_nav = reference.galileoIssue(e.record),
        .sisa_index = x.sisa_index,
        .e1b_hs = x.e1b_hs,
        .e5b_hs = x.e5b_hs,
        .e1b_dvs = x.e1b_dvs,
        .e5b_dvs = x.e5b_dvs,
        .bgd_e1e5a = e.group_delay.get(.bgd_e1e5a) orelse 0,
        .bgd_e1e5b = e.group_delay.get(.bgd_e1e5b) orelse 0,
    };
}

fn misfit(e: *const Parameters) ?[:0]const u8 {
    inline for (.{ &fields.word1, &fields.word2, &fields.word3, &fields.word4, &fields.word5 }) |rows| {
        if (field.misfit(Parameters, rows, e)) |name| return name;
    }
    return null;
}

fn parityOf(eph: *const Parameters) [fec2.parity_len]u8 {
    var info: [fec2.info_len]u8 = undefined;
    inline for (.{ &fields.word1, &fields.word2, &fields.word3, &fields.word4 }, 0..) |layout, k| {
        var word: Word = .{};
        var w = word.writer();
        field.writeDecoded(Parameters, layout, field.project(Parameters, layout, eph), &w);
        const bytes = word.toBytes();
        if (k == 0) {
            info[0] = (bytes[0] & 0xFC) | (bytes[1] & 0x03);
            info[1] = (bytes[0] << 6) | (bytes[1] >> 2);
        }
        info[2 + k * 14 ..][0..14].* = bytes[2..16].*;
    }
    return fec2.parity(&info);
}
