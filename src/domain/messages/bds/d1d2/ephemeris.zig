const time = @import("domain/time/gps");
const reference = @import("domain/navigation/reference");
const klobuchar_fields = @import("domain/messages/fields/klobuchar");
const GpsTime = time.GpsTime;
const Parameters = @import("domain/navigation/orbit/parameters").Parameters;
pub const toe_step_ms = 8000;
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

    pub fn at(self: Metadata, t: GpsTime) Metadata {
        var out = self;
        out.wn = @intCast(@mod(t.inScale(.bds).period, time.week_modulus_13));
        if (self.prediction) |p| {
            out.aodc = ageCode(p, t);
            out.aode = out.aodc;
        }
        return out;
    }
};

pub const Sv = struct {
    eph: Parameters,
    metadata: Metadata,
    klobuchar: klobuchar_fields.Coefficients,
};

pub fn ageCode(prediction: GpsTime, t: GpsTime) u5 {
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
