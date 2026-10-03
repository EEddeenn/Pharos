const field = @import("../../../codec.zig").field;
const time = @import("../../../core.zig").time;
const GpsTime = time.GpsTime;
const reference = @import("../../reference.zig");
const Parameters = @import("../../kepler_parameters.zig").Parameters;
const klobuchar_fields = @import("../../klobuchar_fields.zig");

pub const toe_step_ms = 8000;
pub const tenths_of_ns_per_s = 1e10;

pub fn sowRow(comptime Source: type) field.Field(Source) {
    return .{ .name = "sow_lsb", .width = 12, .src = .{ .ctx = "sow_lsb" } };
}
pub fn rev(comptime Source: type) field.Field(Source) {
    return .{ .name = "rev", .width = 1, .src = .reserved };
}

pub fn reserved(comptime Source: type, comptime name: [:0]const u8, comptime width: u7) field.Field(Source) {
    return .{ .name = name, .width = width, .src = .reserved };
}

const no_accuracy_prediction: u4 = 15;

pub const Metadata = struct {
    sat_h1: bool,
    aodc: u5,
    aode: u5,
    urai: u4,
    wn: u13,
    toc_8s: u17,
    toe_8s: u17,
    tgd1: f64,
    tgd2: f64,
    prediction: ?GpsTime,
};

pub const Sv = struct {
    eph: Parameters,
    metadata: Metadata,
    klobuchar: klobuchar_fields.Coefficients,

    pub fn at(self: Sv, t: GpsTime) Sv {
        var out = self;
        out.metadata.wn = @intCast(@mod(t.inScale(.bds).period, time.week_modulus_13));
        if (self.metadata.prediction) |p| {
            out.metadata.aodc = ageCode(p, t);
            out.metadata.aode = out.metadata.aodc;
        }
        return out;
    }
};

fn ageCode(prediction: GpsTime, t: GpsTime) u5 {
    const hour = @divFloor(t.baseMs(.bds, .table), time.ms_per_hour) * time.ms_per_hour;
    const hours = @divFloor(hour - prediction.baseMs(.bds, .table), time.ms_per_hour);
    if (hours <= 24) return @intCast(@max(hours, 0));
    return if (hours > 7 * 24) 31 else @intCast(23 + @divFloor(hours + 23, 24));
}

pub fn metadata(e: reference.Kepler, parameters: *const Parameters) Metadata {
    var sv: Metadata = .{
        .sat_h1 = false,
        .aodc = 0,
        .aode = 0,
        .urai = no_accuracy_prediction,
        .wn = @intCast(@mod(parameters.toe.inScale(.bds).period, time.week_modulus_13)),
        .toc_8s = @intCast(parameters.toc.inScale(.bds).ms / toe_step_ms),
        .toe_8s = @intCast(parameters.toe.inScale(.bds).ms / toe_step_ms),
        .tgd1 = e.group_delay.get(.tgd_b1i) orelse 0,
        .tgd2 = e.group_delay.get(.tgd_b2i) orelse 0,
        .prediction = e.record.top orelse parameters.toe,
    };
    switch (e.record.extra) {
        .d1d2 => |x| {
            sv.aodc = x.aodc;
            sv.aode = x.aode;
            sv.prediction = null;
        },
        else => {},
    }
    switch (e.attribute(.d1d2) orelse e.record.extra) {
        .d1d2 => |x| {
            sv.sat_h1 = x.sat_h1;
            sv.urai = x.ura_index;
        },
        .bcnav1, .bcnav2, .bcnav3 => |x| sv.sat_h1 = x.signalsBad(),
        else => {},
    }
    return sv;
}
