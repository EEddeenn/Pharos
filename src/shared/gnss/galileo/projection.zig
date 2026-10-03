const records = @import("../records.zig");
const reference = @import("../reference.zig");
const galileo = @import("records.zig");

pub fn forSource(e: reference.Kepler, comptime source: records.NavSource) records.KeplerEphemeris {
    var out = e.record.*;
    out.group_delay = e.group_delay.*;
    if (e.record.source() != source) {
        const origin: records.GroupDelayTerm = if (e.record.source() == .fnav) .bgd_e1e5a else .bgd_e1e5b;
        const target: records.GroupDelayTerm = if (source == .fnav) .bgd_e1e5a else .bgd_e1e5b;
        if (e.group_delay.get(origin)) |original| {
            if (e.group_delay.get(target)) |shifted| {
                out.af0 += shifted - original;
            } else {
                out.group_delay.remove(target);
            }
        } else {
            out.group_delay.remove(target);
        }
    }

    out.extra = e.attribute(source) orelse switch (e.record.extra) {
        .inav => |x| blk: {
            const e5a = x.e5a orelse galileo.E5aDeclaration{ .hs = 0, .dvs = false, .sisa_index = galileo.sisa_napa };
            break :blk .{ .fnav = .{
                .sisa_index = e5a.sisa_index,
                .iod_nav = x.iod_nav,
                .e5a_hs = e5a.hs,
                .e5a_dvs = e5a.dvs,
            } };
        },
        else => unreachable,
    };
    @field(out.extra, @tagName(source)).iod_nav = switch (e.record.extra) {
        .inav => |x| x.iod_nav,
        .fnav => |x| x.iod_nav,
        else => unreachable,
    };
    return out;
}
