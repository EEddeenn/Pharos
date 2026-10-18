const std = @import("std");
const field = @import("../../codec.zig").field;
const frame = @import("../../codec.zig").frame;
const records = @import("../records.zig");
const reference = @import("../reference.zig");
const bds_records = @import("records.zig");
const constants = @import("constants.zig");
const Parameters = @import("../kepler_parameters.zig").Parameters;
const GpsTime = @import("../../core.zig").time.GpsTime;

pub const Broadcast = struct { parameters: Parameters, iodc: u16 };

pub const Source = struct {
    eph: Parameters,
    iode: u16,
    iodc: u16,
    top: GpsTime,
    sat_type: bds_records.SatType,

    fn fromRecord(e: *const records.KeplerEphemeris) Source {
        const sat_type: bds_records.SatType = switch (e.extra) {
            .bcnav1, .bcnav2, .bcnav3 => |x| x.sat_type.?,
            else => bds_records.satTypeOf(e.sat.prn(), e.sqrt_a),
        };
        const alignment = e.parameters().alignedToEpochStep();
        const eph = alignment.parameters;
        var orbit_issue = e.iode;
        var clock_issue = e.iodc;
        switch (e.extra) {
            .bcnav1, .bcnav2 => {},
            else => {
                orbit_issue = records.issueOfEpoch(eph.toe, .bds);
                clock_issue = records.issueOfEpoch(eph.toc, .bds);
            },
        }
        return .{
            .eph = eph,
            .iode = orbit_issue,
            .iodc = clock_issue,
            .top = if (alignment.rebased) eph.toe else e.top orelse eph.toe,
            .sat_type = sat_type,
        };
    }

    pub fn fromReference(e: reference.Kepler, source: records.NavSource) Source {
        var out = fromRecord(e.record);
        if (e.attribute(source)) |extra| switch (extra) {
            .bcnav1, .bcnav2, .bcnav3 => |x| if (x.sat_type) |sat_type| {
                out.sat_type = sat_type;
            },
            else => {},
        };
        return out;
    }

    pub fn misfit(self: *const Source) ?[:0]const u8 {
        inline for (.{ &eph1, &eph2, &clock, &iodc }) |rows| if (field.misfit(Source, rows, self)) |name| return name;
        return null;
    }

    pub fn decoded(self: *const Source) ?Broadcast {
        var bits: frame.Bits(field.totalWidth(Source, &broadcast_rows)) = .{};
        var w = bits.writer();
        field.encode(Source, &broadcast_rows, self, .{}, &w) catch return null;
        const raw = field.decode(Source, &broadcast_rows, &bits.words);
        var out = self.eph;
        out.sqrt_a = @sqrt(constants.aRef(self.sat_type) + field.value(Source, &broadcast_rows, "delta_a", raw));
        inline for (.{ "a_dot", "delta_n", "delta_n_dot", "m0", "ecc", "w", "omega0", "i0", "omega_dot", "idot", "cis", "cic", "crs", "crc", "cus", "cuc", "af0", "af1", "af2" }) |name| {
            @field(out, name) = field.value(Source, &broadcast_rows, name, raw);
        }
        return .{ .parameters = out, .iodc = self.iodc };
    }
};
const S = field.Field(Source);

fn iode(s: *const Source) i64 {
    return s.iode & 0xFF;
}
fn clockIssue(s: *const Source) i64 {
    return s.iodc & 0x3FF;
}
fn toe(s: *const Source) i64 {
    return s.eph.toe.inScale(.bds).ms / records.epoch_step_ms;
}
fn toc(s: *const Source) i64 {
    return s.eph.toc.inScale(.bds).ms / records.epoch_step_ms;
}
fn satType(s: *const Source) i64 {
    return @backingInt(s.sat_type);
}
fn deltaA(s: *const Source) f64 {
    return s.eph.sqrt_a * s.eph.sqrt_a - constants.aRef(s.sat_type);
}

pub const eph1 = [_]S{
    .{ .name = "iode", .width = 8, .src = .{ .computed_int = &iode } },
    .{ .name = "toe", .width = 11, .src = .{ .computed_int = &toe } },
    .{ .name = "sat_type", .width = 2, .src = .{ .computed_int = &satType } },
    .{ .name = "delta_a", .width = 26, .repr = .twos, .scale_log2 = -9, .src = .{ .computed = &deltaA } },
    .{ .name = "a_dot", .width = 25, .repr = .twos, .scale_log2 = -21, .src = .{ .field = "eph.a_dot" } },
    .{ .name = "delta_n", .width = 17, .repr = .twos, .scale_log2 = -44, .semicircles = true, .src = .{ .field = "eph.delta_n" } },
    .{ .name = "delta_n_dot", .width = 23, .repr = .twos, .scale_log2 = -57, .semicircles = true, .src = .{ .field = "eph.delta_n_dot" } },
    .{ .name = "m0", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .periodic = true, .src = .{ .field = "eph.m0" } },
    .{ .name = "ecc", .width = 33, .scale_log2 = -34, .src = .{ .field = "eph.ecc" } },
    .{ .name = "w", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .periodic = true, .src = .{ .field = "eph.w" } },
};

pub const eph2 = [_]S{
    .{ .name = "omega0", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .periodic = true, .src = .{ .field = "eph.omega0" } },
    .{ .name = "i0", .width = 33, .repr = .twos, .scale_log2 = -32, .semicircles = true, .src = .{ .field = "eph.i0" } },
    .{ .name = "omega_dot", .width = 19, .repr = .twos, .scale_log2 = -44, .semicircles = true, .src = .{ .field = "eph.omega_dot" } },
    .{ .name = "idot", .width = 15, .repr = .twos, .scale_log2 = -44, .semicircles = true, .src = .{ .field = "eph.idot" } },
    .{ .name = "cis", .width = 16, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cis" } },
    .{ .name = "cic", .width = 16, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cic" } },
    .{ .name = "crs", .width = 24, .repr = .twos, .scale_log2 = -8, .src = .{ .field = "eph.crs" } },
    .{ .name = "crc", .width = 24, .repr = .twos, .scale_log2 = -8, .src = .{ .field = "eph.crc" } },
    .{ .name = "cus", .width = 21, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cus" } },
    .{ .name = "cuc", .width = 21, .repr = .twos, .scale_log2 = -30, .src = .{ .field = "eph.cuc" } },
};

pub const clock = [_]S{
    .{ .name = "toc", .width = 11, .src = .{ .computed_int = &toc } },
    .{ .name = "af0", .width = 25, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "eph.af0" } },
    .{ .name = "af1", .width = 22, .repr = .twos, .scale_log2 = -50, .src = .{ .field = "eph.af1" } },
    .{ .name = "af2", .width = 11, .repr = .twos, .scale_log2 = -66, .src = .{ .field = "eph.af2" } },
};

pub const iodc = [_]S{.{ .name = "iodc", .width = 10, .src = .{ .computed_int = &clockIssue } }};

const broadcast_rows = eph1 ++ eph2 ++ clock;

pub fn misfit(e: *const records.KeplerEphemeris) ?[:0]const u8 {
    const source = Source.fromRecord(e);
    return source.misfit();
}

comptime {
    std.debug.assert(field.totalWidth(Source, &eph1) == 211);
    std.debug.assert(field.totalWidth(Source, &eph2) == 222);
    std.debug.assert(field.totalWidth(Source, &clock) == 69);
    std.debug.assert(field.totalWidth(Source, &iodc) == 10);
}
