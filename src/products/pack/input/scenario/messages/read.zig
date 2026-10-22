const std = @import("std");
const text = @import("domain/messages/gps/text");
const grid = @import("domain/messages/bds/d1d2/grid");
const integrity = @import("domain/messages/bds/d1d2/integrity");
const augmentation = @import("domain/messages/bds/d1d2/augmentation");
const ism = @import("domain/messages/galileo/inav/ism");
const gps_ism = @import("domain/messages/gps/ism");
const publication = @import("domain/messages/gps/publication");
const messages_publication = @import("domain/messages/publication");
const json_schema = @import("base/json/schema");
const json_node = @import("base/json/node");
const json_table = @import("base/json/table");
const time = @import("products/pack/input/scenario/time");
const gps = @import("products/pack/input/scenario/messages/gps");
const inav = @import("products/pack/input/scenario/messages/inav");
const d2 = @import("products/pack/input/scenario/messages/d2");
const Messages = @import("simulation/model/publications").Publications;
const Key = json_table.Key;
const Ctx = json_node.Ctx;
const Error = json_node.Error;

pub const Raw = struct {
    gps: ?[]const gps.RawPublication = null,
    galileo: ?RawGalileo = null,
    bds: ?RawBds = null,

    pub const table = [_]Key{
        .{ .name = "gps", .doc = "publications of LNAV, CNAV and CNAV-2, ordered and not overlapping" },
        .{ .name = "galileo", .doc = "Galileo publications" },
        .{ .name = "bds", .doc = "BDS publications" },
    };

    pub fn schemaMetadata(s: *json_schema.Schema) std.Io.Writer.Error!void {
        try s.begin("x-publication");
        try s.begin("gps");
        const Configuration = @typeInfo(@FieldType(publication.Declaration, "configuration")).optional.child;
        try s.jw.objectField("configurationCount");
        try s.jw.write(@typeInfo(Configuration).array.len);
        try s.jw.objectField("textLength");
        try s.jw.write(text.max_len);
        try s.jw.objectField("ismGridMs");
        try s.jw.write(gps_ism.tow_step_ms);
        try s.begin("identifiers");
        inline for (comptime std.enums.values(gps_ism.Constellation)) |constellation| {
            try s.jw.objectField(comptime gps_ism.Constellation.words.get(constellation));
            try s.jw.write(constellation.identifiers());
        }
        try s.end();
        try s.end();
        try s.jw.objectField("inav");
        try s.jw.write(.{
            .testHexDigits = (@bitSizeOf(@FieldType(ism.Ism, "test_message")) + 3) / 4,
            .referenceGridMs = ism.tow_step_ms,
            .bankSize = @bitSizeOf(@FieldType(ism.Sl3, "mask")),
        });
        try s.jw.objectField("d2");
        try s.jw.write(.{ .gridCount = grid.igp_count, .maxSatellites = integrity.max_packets });
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
        const list_path = try json_node.join(ctx, path, "gps");
        if (try publications(publication.Publication, gps.RawPublication, entries, gps.resolve, ctx, list_path)) |p| result.gps = p else ok = false;
    }
    if (raw.galileo) |g| if (g.inav) |entries| {
        const list_path = try json_node.join(ctx, try json_node.join(ctx, path, "galileo"), "inav");
        if (try publications(ism.Publication, inav.RawPublication, entries, inav.resolve, ctx, list_path)) |p| result.inav = p else ok = false;
    };
    if (raw.bds) |b| if (b.d2) |entries| {
        const list_path = try json_node.join(ctx, try json_node.join(ctx, path, "bds"), "d2");
        if (try publications(augmentation.Publication, d2.RawPublication, entries, d2.resolve, ctx, list_path)) |p| result.d2 = p else ok = false;
    };
    return if (ok) result else null;
}

fn publications(comptime Publication: type, comptime RawPub: type, entries: []const RawPub, comptime resolveContent: anytype, ctx: *const Ctx, path: []const u8) Error!?[]const Publication {
    const out = try ctx.arena.alloc(Publication, entries.len);
    var previous_until: ?@FieldType(Publication, "until") = null;
    var ok = true;
    for (entries, 0..) |entry, i| {
        const entry_path = try json_node.element(ctx, path, i);
        const resolved_from = try time.resolve(entry.from, ctx, try json_node.join(ctx, entry_path, "from"));
        const resolved_until = try time.resolve(entry.until, ctx, try json_node.join(ctx, entry_path, "until"));
        const content = try resolveContent(entry, ctx, entry_path);
        const from = resolved_from orelse {
            ok = false;
            continue;
        };
        const until = resolved_until orelse {
            ok = false;
            continue;
        };
        if (!messages_publication.interval(from, until)) {
            try ctx.diags.err(.out_of_range, try json_node.join(ctx, entry_path, "until"), "must be later than from", .{});
            ok = false;
        }
        if (!messages_publication.follows(from, previous_until)) {
            try ctx.diags.err(.out_of_range, try json_node.join(ctx, entry_path, "from"), "publication intervals must be ordered and non-overlapping", .{});
            ok = false;
        }
        previous_until = until;
        if (content) |supplied| out[i] = .{ .from = from, .until = until, .content = supplied } else ok = false;
    }
    return if (ok) out else null;
}
