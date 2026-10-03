const std = @import("std");
const gnss = @import("shared").gnss;
const schema = @import("shared").json.schema;
const node = @import("shared").json.node;
const table = @import("shared").json.table;
const time = @import("time.zig");
const gps = @import("messages/gps.zig");
const inav = @import("messages/inav.zig");
const d2 = @import("messages/d2.zig");
const Messages = @import("shared").bundle.messages.Messages;
const Key = table.Key;
const Ctx = node.Ctx;
const Error = node.Error;

pub const Raw = struct {
    gps: ?[]const gps.RawPublication = null,
    galileo: ?RawGalileo = null,
    bds: ?RawBds = null,

    pub const table = [_]Key{
        .{ .name = "gps", .doc = "publications of LNAV, CNAV and CNAV-2, ordered and not overlapping" },
        .{ .name = "galileo", .doc = "Galileo publications" },
        .{ .name = "bds", .doc = "BDS publications" },
    };

    pub fn schemaMetadata(s: *schema.Schema) std.Io.Writer.Error!void {
        try s.begin("x-publication");
        try s.begin("gps");
        const Configuration = @typeInfo(@FieldType(gnss.gps.messages.Sources, "configuration")).optional.child;
        try s.jw.objectField("configurationCount");
        try s.jw.write(@typeInfo(Configuration).array.len);
        try s.jw.objectField("textLength");
        try s.jw.write(gnss.gps.text.max_len);
        try s.jw.objectField("ismGridMs");
        try s.jw.write(gnss.gps.ism.tow_step_ms);
        try s.begin("identifiers");
        inline for (comptime std.enums.values(gnss.gps.ism.Constellation)) |constellation| {
            try s.jw.objectField(comptime gnss.gps.ism.Constellation.words.get(constellation));
            try s.jw.write(constellation.identifiers());
        }
        try s.end();
        try s.end();
        try s.jw.objectField("inav");
        try s.jw.write(.{
            .testHexDigits = (@bitSizeOf(@FieldType(gnss.galileo.inav.ism.Ism, "test_message")) + 3) / 4,
            .referenceGridMs = gnss.galileo.inav.ism.tow_step_ms,
            .bankSize = @bitSizeOf(@FieldType(gnss.galileo.inav.ism.Sl3, "mask")),
        });
        try s.jw.objectField("d2");
        try s.jw.write(.{ .gridCount = gnss.bds.d1d2.grid.igp_count, .maxSatellites = gnss.bds.d1d2.integrity.max_packets });
        try s.end();
    }
};

const RawGalileo = struct {
    inav: ?[]const inav.RawPublication = null,

    pub const table = [_]Key{.{ .name = "inav", .doc = "publications of I/NAV's integrity support message, ordered and not overlapping" }};
};

const RawBds = struct {
    d2: ?[]const d2.RawPublication = null,

    pub const table = [_]Key{.{ .name = "d2", .doc = "publications of the D2 augmentation of the GEO satellites, ordered and not overlapping" }};
};

pub fn resolve(raw: Raw, ctx: *const Ctx, path: []const u8) Error!?Messages {
    var result: Messages = .{};
    var ok = true;
    if (raw.gps) |entries| {
        const list_path = try node.join(ctx, path, "gps");
        if (try publications(gnss.gps.messages.Publication, gps.RawPublication, entries, gps.resolve, ctx, list_path)) |p| result.gps = p else ok = false;
    }
    if (raw.galileo) |g| if (g.inav) |entries| {
        const list_path = try node.join(ctx, try node.join(ctx, path, "galileo"), "inav");
        if (try publications(gnss.galileo.inav.ism.Publication, inav.RawPublication, entries, inav.resolve, ctx, list_path)) |p| result.inav = p else ok = false;
    };
    if (raw.bds) |b| if (b.d2) |entries| {
        const list_path = try node.join(ctx, try node.join(ctx, path, "bds"), "d2");
        if (try publications(gnss.bds.d1d2.augmentation.Publication, d2.RawPublication, entries, d2.resolve, ctx, list_path)) |p| result.d2 = p else ok = false;
    };
    return if (ok) result else null;
}

fn publications(comptime Publication: type, comptime RawPub: type, entries: []const RawPub, comptime resolveContent: anytype, ctx: *const Ctx, path: []const u8) Error!?[]const Publication {
    const out = try ctx.arena.alloc(Publication, entries.len);
    var previous_until: ?@FieldType(Publication, "until") = null;
    var ok = true;
    for (entries, 0..) |entry, i| {
        const entry_path = try node.element(ctx, path, i);
        const resolved_from = try time.resolve(entry.from, ctx, try node.join(ctx, entry_path, "from"));
        const resolved_until = try time.resolve(entry.until, ctx, try node.join(ctx, entry_path, "until"));
        const content = try resolveContent(entry, ctx, entry_path);
        const from = resolved_from orelse {
            ok = false;
            continue;
        };
        const until = resolved_until orelse {
            ok = false;
            continue;
        };
        if (!gnss.publication.interval(from, until)) {
            try ctx.diags.err(.out_of_range, try node.join(ctx, entry_path, "until"), "must be later than from", .{});
            ok = false;
        }
        if (!gnss.publication.follows(from, previous_until)) {
            try ctx.diags.err(.out_of_range, try node.join(ctx, entry_path, "from"), "publication intervals must be ordered and non-overlapping", .{});
            ok = false;
        }
        previous_until = until;
        if (content) |supplied| out[i] = .{ .from = from, .until = until, .content = supplied } else ok = false;
    }
    return if (ok) out else null;
}
