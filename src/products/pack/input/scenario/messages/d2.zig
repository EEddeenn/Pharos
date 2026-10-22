const std = @import("std");
const d1d2_grid = @import("domain/messages/bds/d1d2/grid");
const d1d2_integrity = @import("domain/messages/bds/d1d2/integrity");
const json_node = @import("base/json/node");
const json_table = @import("base/json/table");
const time = @import("products/pack/input/scenario/time");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const Key = json_table.Key;
const Ctx = json_node.Ctx;
const Error = json_node.Error;

pub const RawPublication = struct {
    from: time.Raw = undefined,
    until: time.Raw = undefined,
    integrity: ?RawIntegrity = null,
    grid: ?RawGrid = null,

    pub const table = [_]Key{
        .{ .name = "from", .required = true, .doc = "the instant the publication comes into force" },
        .{ .name = "until", .required = true, .doc = "the instant it leaves force, later than from" },
        .{ .name = "integrity", .doc = "the integrity and correction declaration of subframes 2 to 4; absent: none" },
        .{ .name = "grid", .doc = "the declaration of the grid pages; absent: none" },
    };
};

const RawIntegrity = struct {
    check: augmentation.Check = undefined,
    satellites: []const RawSatellite = undefined,

    pub const table = [_]Key{
        .{ .name = "check", .required = true, .what = "check result", .doc = "the MSB of SatH2: good or bad" },
        .{ .name = "satellites", .required = true, .doc = "the satellites described, at most 24; an empty array declares none" },
    };
};

const RawSatellite = struct {
    svid: []const u6 = undefined,
    rurai: u4 = undefined,
    udrei: u4 = undefined,

    pub const table = [_]Key{
        .{ .name = "svid", .required = true, .one_or_many = true, .range = .{ .min = 1, .max = 63 }, .doc = "the BDS satellites, none repeated" },
        .{ .name = "rurai", .required = true, .doc = "the RURA index" },
        .{ .name = "udrei", .required = true, .doc = "the UDRE index, sent as 15 while the satellite has no correction" },
    };
};

const RawGrid = struct {
    check: augmentation.Check = undefined,
    givei: []const u4 = undefined,
    not_monitored: ?[]const u16 = null,

    pub const table = [_]Key{
        .{ .name = "check", .required = true, .what = "check result", .doc = "the LSB of SatH2: good or bad" },
        .{ .name = "givei", .required = true, .one_or_many = true, .doc = std.fmt.comptimePrint("one GIVE index for every grid point, or {d} in grid-point order", .{d1d2_grid.igp_count}) },
        .{ .name = "notMonitored", .range = .{ .min = 1, .max = d1d2_grid.igp_count }, .doc = "the grid points sent as not monitored, none repeated; absent: none" },
    };
};

pub fn resolve(raw: RawPublication, ctx: *const Ctx, path: []const u8) Error!?augmentation.Declaration {
    var ok = true;
    var result: augmentation.Declaration = .{};
    if (raw.integrity) |i| {
        if (try integrityOf(i, ctx, try json_node.join(ctx, path, "integrity"))) |v| result.integrity = v else ok = false;
    }
    if (raw.grid) |g| {
        if (try gridOf(g, ctx, try json_node.join(ctx, path, "grid"))) |v| result.grid = v else ok = false;
    }
    return if (ok) result else null;
}

fn integrityOf(raw: RawIntegrity, ctx: *const Ctx, path: []const u8) Error!?augmentation.Integrity {
    var out: augmentation.Integrity = .{ .check = raw.check, .sv = @splat(null) };
    const list_path = try json_node.join(ctx, path, "satellites");
    var ok = true;
    var count: usize = 0;
    for (raw.satellites, 0..) |entry, i| {
        for (entry.svid) |svid| {
            if (out.sv[svid - 1] != null) {
                try ctx.diags.err(.duplicate, try json_node.join(ctx, try json_node.element(ctx, list_path, i), "svid"), "satellite {d} is repeated", .{svid});
                ok = false;
                continue;
            }
            out.sv[svid - 1] = .{ .rurai = entry.rurai, .udrei = entry.udrei };
            count += 1;
        }
    }
    if (count > d1d2_integrity.max_packets) {
        try ctx.diags.err(.out_of_range, list_path, "D2 describes at most {d} satellites ({d} in subframes 2 and 3, the rest in subframe 4), got {d}", .{ d1d2_integrity.max_packets, d1d2_integrity.basic_packets, count });
        ok = false;
    }
    return if (ok) out else null;
}

fn gridOf(raw: RawGrid, ctx: *const Ctx, path: []const u8) Error!?augmentation.Grid {
    const count = d1d2_grid.igp_count;
    var out: augmentation.Grid = .{ .check = raw.check, .givei = @splat(0), .monitored = @splat(true) };
    var ok = true;
    const givei = raw.givei;
    if (givei.len == 1) {
        out.givei = @splat(givei[0]);
    } else if (givei.len == count) {
        out.givei = givei[0..count].*;
    } else {
        try ctx.diags.err(.out_of_range, try json_node.join(ctx, path, "givei"), "takes one index for every grid point or {d}, got {d}", .{ count, givei.len });
        ok = false;
    }
    const list_path = try json_node.join(ctx, path, "notMonitored");
    for (raw.not_monitored orelse &.{}, 0..) |igp, i| {
        if (!out.monitored[igp - 1]) {
            try ctx.diags.err(.duplicate, try json_node.element(ctx, list_path, i), "grid point {d} is repeated", .{igp});
            ok = false;
        }
        out.monitored[igp - 1] = false;
    }
    return if (ok) out else null;
}
