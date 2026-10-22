const scaling = @import("base/binary/scaling");
const dictionary = @import("base/text/dictionary");
const publication = @import("domain/messages/publication");
const integrity = @import("domain/messages/bds/d1d2/integrity");
const grid = @import("domain/messages/bds/d1d2/grid");
const Supplier = @import("domain/messages/supplier").Supplier;
pub const Check = enum(u1) {
    good = 0,
    bad = 1,

    pub const words = dictionary.tagNames(Check);
};

const Indices = struct { rurai: u4, udrei: u4 };
pub const Integrity = struct { check: Check, sv: [63]?Indices };
pub const Grid = struct { check: Check, givei: [grid.igp_count]u4, monitored: [grid.igp_count]bool };
pub const Declaration = struct { integrity: ?Integrity = null, grid: ?Grid = null };
pub const Publication = publication.Publication(Declaration);
const Listed = struct {
    check: Check,
    count: u5,
    svid: [integrity.max_packets]u6,
    indices: [integrity.max_packets]Indices,
};

pub const Prepared = struct {
    integrity: ?Listed,
    grid: ?*const Grid,

    pub fn init(d: *const Declaration) Prepared {
        var out: Prepared = .{ .integrity = null, .grid = if (d.grid) |*g| g else null };
        if (d.integrity) |declared| {
            var list: Listed = .{ .check = declared.check, .count = 0, .svid = undefined, .indices = undefined };
            for (declared.sv, 1..) |entry, id| if (entry) |indices| {
                list.svid[list.count] = @intCast(id);
                list.indices[list.count] = indices;
                list.count += 1;
            };
            out.integrity = list;
        }
        return out;
    }
};
pub const PreparedPublication = publication.Publication(Prepared);
pub const CorrectionPayload = struct { corrections: [integrity.max_packets]?f64, grid: ?[grid.points_per_page]u9 = null };
pub const Source = Supplier(i64, CorrectionPayload);
const delta_t_codes_per_m = 10.0;
const delta_t_code_max = 4095;

pub fn block(p: ?*const Prepared, corrections: []const ?f64) integrity.Block {
    const prepared = p orelse return integrity.Block.none;
    const msb: u2 = if (prepared.integrity) |list| @backingInt(list.check) else 1;
    const lsb: u2 = if (prepared.grid) |g| @backingInt(g.check) else 1;
    var out: integrity.Block = .{ .sat_h2 = (msb << 1) | lsb };
    const list = prepared.integrity orelse return out;
    for (list.svid[0..list.count], list.indices[0..list.count], 0..) |id, indices, k| {
        const code: ?i64 = if (corrections[k]) |m| scaling.roundWithin(m * delta_t_codes_per_m, -delta_t_code_max, delta_t_code_max) else null;
        out.bdid[id - 1] = true;
        out.packets[k] = .{
            .rurai = indices.rurai,
            .udrei = if (code != null) indices.udrei else 15,
            .delta_t = if (code) |q| @intCast(q) else integrity.delta_t_unavailable,
        };
        out.expanded = out.expanded or id > integrity.basic_ids or k >= integrity.basic_packets;
    }
    return out;
}

pub fn gridPage(p: ?*const Prepared, pnum: u7, delays: ?*const [grid.points_per_page]u9) grid.Page {
    var page: grid.Page = .{ .pnum = pnum, .ions = @splat(grid.unavailable) };
    const published = (p orelse return page).grid orelse return page;
    const codes = delays orelse return page;
    const igps = grid.igpsOf(pnum);
    for (page.ions[0..igps.count], @as(usize, igps.first) - 1.., 0..) |*ion, j, k| {
        if (!published.monitored[j]) {
            ion.* = .{ .dtau = grid.not_monitored, .givei = 15 };
        } else if (codes[k] != grid.not_available) {
            ion.* = .{ .dtau = codes[k], .givei = published.givei[j] };
        }
    }
    return page;
}
