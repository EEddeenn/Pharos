const std = @import("std");
const dictionary = @import("shared").core.dictionary;
const ism = @import("shared").gnss.galileo.inav.ism;
const json = @import("shared").json;
const node = json.node;
const table = json.table;
const time = @import("../time.zig");
const Key = table.Key;
const Ctx = node.Ctx;
const Error = node.Error;

const Service = enum {
    @"test",
    noData,
    horizontal,

    pub const words = dictionary.tagNames(Service);
};

pub const RawPublication = struct {
    from: time.Raw = undefined,
    until: time.Raw = undefined,
    ism: RawIsm = undefined,

    pub const table = [_]Key{
        .{ .name = "from", .required = true, .doc = "the instant the publication comes into force" },
        .{ .name = "until", .required = true, .doc = "the instant it leaves force, later than from" },
        .{ .name = "ism", .required = true, .doc = "the integrity support message of I/NAV word 22" },
    };
};

const RawIsm = struct {
    service: Service = undefined,
    test_message: ?[]const u8 = null,
    reference: ?time.Raw = null,
    satellites: ?[]const u32 = null,
    p_const: ?u4 = null,
    p_sat: ?u4 = null,
    ura: ?u4 = null,
    ure: ?u4 = null,
    b_nom: ?u4 = null,
    t_validity: ?u4 = null,

    pub const table = [_]Key{
        .{ .name = "service", .required = true, .doc = "the service: test, noData or horizontal; a key another service takes draws a warning" },
        .{ .name = "testMessage", .what = "test message", .doc = "exactly 22 hexadecimal digits, the first 0 to 7" },
        .{ .name = "reference", .doc = "the reference time, on the whole 30-minute grid of GST" },
        .{ .name = "satellites", .range = .{ .min = 1, .max = 63 }, .doc = "satellites of one mask bank, 1 to 32 or 33 to 63, none repeated; may be empty" },
        .{ .name = "pConst", .doc = "the constellation fault probability index" },
        .{ .name = "pSat", .doc = "the satellite fault probability index" },
        .{ .name = "ura", .doc = "the URA index" },
        .{ .name = "ure", .doc = "the URE index" },
        .{ .name = "bNom", .doc = "the nominal bias index" },
        .{ .name = "tValidity", .doc = "the validity index" },
    };

    pub const kinds: json.table.Kinds(Service) = .{ .key = "service", .of = .init(.{
        .@"test" = .{ .keys = &.{.{ .name = "testMessage", .required = true }} },
        .noData = .{},
        .horizontal = .{ .keys = &.{
            .{ .name = "reference", .required = true },
            .{ .name = "satellites", .required = true },
            .{ .name = "pConst", .required = true },
            .{ .name = "pSat", .required = true },
            .{ .name = "ura", .required = true },
            .{ .name = "ure", .required = true },
            .{ .name = "bNom", .required = true },
            .{ .name = "tValidity", .required = true },
        } },
    }) };
};

pub fn resolve(raw: RawPublication, ctx: *const Ctx, path: []const u8) Error!?ism.Ism {
    const ism_path = try node.join(ctx, path, "ism");
    return switch (try table.kind(RawIsm, raw.ism, ctx, ism_path) orelse return null) {
        .@"test" => |given| .{ .test_message = try testMessage(given.test_message, ctx, ism_path) orelse return null },
        .noData => .no_data,
        .horizontal => |given| .{ .horizontal = try horizontal(given, ctx, ism_path) orelse return null },
    };
}

fn testMessage(text: []const u8, ctx: *const Ctx, path: []const u8) Error!?u87 {
    const key_path = try node.join(ctx, path, "testMessage");
    if (text.len != 22 or text[0] < '0' or text[0] > '7') {
        try ctx.diags.err(.out_of_range, key_path, "must be exactly 22 hexadecimal digits, the first from 0 to 7", .{});
        return null;
    }
    var result: u87 = 0;
    for (text) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch {
            try ctx.diags.err(.out_of_range, key_path, "must contain only hexadecimal digits", .{});
            return null;
        };
        result = (result << 4) | digit;
    }
    return result;
}

const Mask = struct { msb: bool, bits: u32 };

fn satelliteMask(ids: []const u32, ctx: *const Ctx, path: []const u8) Error!?Mask {
    var bank: ?bool = null;
    var bits: u32 = 0;
    var ok = true;
    for (ids, 0..) |svid, i| {
        const item_path = try node.element(ctx, path, i);
        const msb = svid >= 33;
        if (bank) |selected| {
            if (selected != msb) {
                try ctx.diags.err(.out_of_range, item_path, "satellites must share one mask bank: from 1 to 32 or from 33 to 63", .{});
                ok = false;
                continue;
            }
        } else bank = msb;
        const position: u5 = @intCast((svid - 1) % 32);
        const bit = @as(u32, 1) << (31 - position);
        if (bits & bit != 0) {
            try ctx.diags.err(.duplicate, item_path, "satellite {d} is repeated", .{svid});
            ok = false;
        }
        bits |= bit;
    }
    return if (ok) .{ .msb = bank orelse false, .bits = bits } else null;
}

fn horizontal(given: @FieldType(table.Resolved(RawIsm), "horizontal"), ctx: *const Ctx, path: []const u8) Error!?ism.Sl3 {
    const reference = try time.resolve(given.reference, ctx, try node.join(ctx, path, "reference"));
    const mask = try satelliteMask(given.satellites, ctx, try node.join(ctx, path, "satellites"));
    const t = reference orelse return null;
    const m = mask orelse return null;
    if (t.sub_ms != 0 or @mod(t.ms, ism.tow_step_ms) != 0) {
        try ctx.diags.err(.out_of_range, try node.join(ctx, path, "reference"), "must lie on the whole 30-minute grid of GST, the ISM time of week counting 30-minute units", .{});
        return null;
    }
    return .{
        .reference = t,
        .mask_msb = m.msb,
        .mask = m.bits,
        .p_const = given.p_const,
        .p_sat = given.p_sat,
        .ura = given.ura,
        .ure = given.ure,
        .b_nom = given.b_nom,
        .t_validity = given.t_validity,
    };
}
