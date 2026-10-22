const field = @import("base/binary/field");
const records = @import("domain/navigation/records");
const Sv = @import("domain/messages/bds/bcnav/content").Candidate;
const S = field.Field(Sv);

pub const sisai_oe = [_]S{.{ .name = "sisai_oe", .width = 5, .src = .{ .field = "sisai_oe" } }};
pub const sisai_oc = [_]S{
    .{ .name = "top", .width = 11, .src = .{ .computed_int = &top } },
    .{ .name = "sisai_ocb", .width = 5, .src = .{ .field = "sisai_ocb" } },
    .{ .name = "sisai_oc1", .width = 3, .src = .{ .field = "sisai_oc1" } },
    .{ .name = "sisai_oc2", .width = 3, .src = .{ .field = "sisai_oc2" } },
};

fn top(s: *const Sv) i64 {
    return s.ephemeris.top.inScale(.bds).ms / records.epoch_step_ms;
}
