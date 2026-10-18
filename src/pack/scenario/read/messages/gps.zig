const std = @import("std");
const gps = @import("shared").gnss.gps;

const degree_utf8 = "\xC2\xB0";
const node = @import("shared").json.node;
const table = @import("shared").json.table;
const time = @import("../time.zig");
const Key = table.Key;
const Ctx = node.Ctx;
const Error = node.Error;

const configuration_codes = 63;
const index_range: table.Range = .{ .min = 0, .max = 14 };

pub const RawPublication = struct {
    from: time.Raw = undefined,
    until: time.Raw = undefined,
    integrity: ?RawIntegrity = null,
    text: ?[]const u8 = null,
    configuration: ?[]const u32 = null,
    ism: ?RawIsm = null,
    differential: ?RawDifferential = null,

    pub const table = [_]Key{
        .{ .name = "from", .required = true, .doc = "the instant the publication comes into force" },
        .{ .name = "until", .required = true, .doc = "the instant it leaves force, later than from" },
        .{ .name = "integrity", .doc = "the integrity status flag and the alert flags; absent: none" },
        .{ .name = "text", .doc = std.fmt.comptimePrint("a text message of 1 to {d} broadcast characters: A to Z, 0 to 9, space, + - . ' / : \" and the degree sign; absent: none", .{gps.text.max_len}) },
        .{ .name = "configuration", .items = .{ .min = configuration_codes, .max = configuration_codes }, .range = .{ .min = 0, .max = 5 }, .doc = "the configuration codes of SV 1 onwards; absent: the codes of the allocation at the run start" },
        .{ .name = "ism", .doc = "the integrity support message; absent: none" },
        .{ .name = "differential", .doc = "the accuracy of the differential corrections; absent: none" },
    };
};

const RawIntegrity = struct {
    isf: u8 = undefined,
    alert: ?[]const u32 = null,

    pub const table = [_]Key{
        .{ .name = "isf", .required = true, .range = .{ .min = 0, .max = 1 }, .doc = "the integrity status flag" },
        .{ .name = "alert", .one_or_many = true, .range = .{ .min = 1, .max = 32 }, .doc = "the PRNs sent with the alert flag, each once; absent: none" },
    };
};

const udra_range: table.Range = .{ .min = -16, .max = 15 };

const RawDifferential = struct {
    udra: i8 = undefined,
    udra_rate: i8 = undefined,

    pub const table = [_]Key{
        .{ .name = "udra", .required = true, .range = udra_range, .doc = "the UDRA index" },
        .{ .name = "udraRate", .required = true, .range = udra_range, .doc = "the UDRA rate index" },
    };
};

const RawIsm = struct {
    reference: time.Raw = undefined,
    constellation: gps.ism.Constellation = undefined,
    service: gps.ism.Service = undefined,
    satellites: []const u32 = undefined,
    t_correl: u4 = undefined,
    b_nom: u4 = undefined,
    gamma_nom: u4 = undefined,
    r_sat: u4 = undefined,
    p_const: u4 = undefined,
    mfd: u4 = undefined,

    pub const table = [_]Key{
        .{ .name = "reference", .required = true, .doc = "the ISM's reference time, on the whole 4-hour grid of GPS time" },
        .{ .name = "constellation", .required = true, .doc = "the constellation the message describes" },
        .{ .name = "service", .required = true, .doc = "the service level" },
        .{ .name = "satellites", .required = true, .doc = "identifiers of the constellation, each once; may be empty" },
        .{ .name = "tCorrel", .required = true, .range = index_range, .doc = "the correlation time index" },
        .{ .name = "bNom", .required = true, .doc = "the nominal bias index" },
        .{ .name = "gammaNom", .required = true, .doc = "the nominal gamma index" },
        .{ .name = "rSat", .required = true, .range = index_range, .doc = "the satellite fault rate index" },
        .{ .name = "pConst", .required = true, .range = index_range, .doc = "the constellation fault probability index" },
        .{ .name = "mfd", .required = true, .doc = "the mean fault duration index" },
    };
};

pub fn resolve(raw: RawPublication, ctx: *const Ctx, path: []const u8) Error!?gps.messages.Sources {
    var ok = true;
    var result: gps.messages.Sources = .{};
    if (raw.integrity) |i| {
        if (try integrity(i, ctx, try node.join(ctx, path, "integrity"))) |v| result.integrity = v else ok = false;
    }
    if (raw.text) |t| {
        if (try text(t, ctx, try node.join(ctx, path, "text"))) |v| result.text = v else ok = false;
    }
    if (raw.configuration) |codes| result.configuration = configuration(codes);
    if (raw.ism) |i| {
        if (try ism(i, ctx, try node.join(ctx, path, "ism"))) |v| result.ism = v else ok = false;
    }
    if (raw.differential) |d| result.differential = .{ .udra = @intCast(d.udra), .udra_rate = @intCast(d.udra_rate) };
    return if (ok) result else null;
}

fn integrity(raw: RawIntegrity, ctx: *const Ctx, path: []const u8) Error!?gps.messages.Integrity {
    var alert: u32 = 0;
    var ok = true;
    for (raw.alert orelse &.{}, 0..) |prn, i| {
        const bit = @as(u32, 1) << @intCast(prn - 1);
        if (alert & bit != 0) {
            try ctx.diags.err(.duplicate, try node.element(ctx, try node.join(ctx, path, "alert"), i), "PRN {d} occurs more than once", .{prn});
            ok = false;
        }
        alert |= bit;
    }
    return if (ok) .{ .isf = @intCast(raw.isf), .alert = alert } else null;
}

fn text(source: []const u8, ctx: *const Ctx, path: []const u8) Error!?[]const u8 {
    const out = try ctx.arena.alloc(u8, source.len);
    var count: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        var c = source[i];
        if (c == degree_utf8[0] and i + 1 < source.len and source[i + 1] == degree_utf8[1]) {
            c = gps.text.degree;
            i += 1;
        } else if (c == gps.text.degree or !gps.text.allowed(c)) {
            try ctx.diags.err(.out_of_range, path, "contains a character outside the broadcast alphabet", .{});
            return null;
        }
        out[count] = c;
        count += 1;
    }
    if (count == 0 or count > gps.text.max_len) {
        try ctx.diags.err(.out_of_range, path, "must contain 1 to {d} broadcast characters", .{gps.text.max_len});
        return null;
    }
    return out[0..count];
}

fn configuration(codes: []const u32) [configuration_codes]u3 {
    var result: [configuration_codes]u3 = undefined;
    for (codes, &result) |code, *r| r.* = @intCast(code);
    return result;
}

fn ism(raw: RawIsm, ctx: *const Ctx, path: []const u8) Error!?gps.ism.Ism {
    const reference_path = try node.join(ctx, path, "reference");
    const reference = try time.resolve(raw.reference, ctx, reference_path);
    const mask = try satelliteMask(raw.satellites, raw.constellation, ctx, try node.join(ctx, path, "satellites"));
    if (reference) |t| if (t.sub_ms != 0 or @mod(t.ms, gps.ism.tow_step_ms) != 0) {
        try ctx.diags.err(.out_of_range, reference_path, "must lie on the whole 4-hour grid of GPS time, the ISM time of week counting 4-hour units", .{});
        return null;
    };
    return .{
        .reference = reference orelse return null,
        .constellation = raw.constellation,
        .t_correl = raw.t_correl,
        .b_nom = raw.b_nom,
        .gamma_nom = raw.gamma_nom,
        .r_sat = raw.r_sat,
        .p_const = raw.p_const,
        .mfd = raw.mfd,
        .service = raw.service,
        .mask = mask orelse return null,
    };
}

fn satelliteMask(ids: []const u32, constellation: gps.ism.Constellation, ctx: *const Ctx, path: []const u8) Error!?u63 {
    const range = constellation.identifiers() orelse {
        if (ids.len == 0) return 0;
        try ctx.diags.err(.out_of_range, path, "unavailable constellation has no satellite identifier mapping", .{});
        return null;
    };
    var mask: u63 = 0;
    var ok = true;
    for (ids, 0..) |id, i| {
        const bit = constellation.bitOf(id) orelse {
            try ctx.diags.err(.out_of_range, try node.element(ctx, path, i), "satellite must be from {d} to {d}, got {d}", .{ range.first, range.last, id });
            ok = false;
            continue;
        };
        if (mask & bit != 0) {
            try ctx.diags.err(.duplicate, try node.element(ctx, path, i), "satellite {d} occurs more than once", .{id});
            ok = false;
        }
        mask |= bit;
    }
    return if (ok) mask else null;
}
