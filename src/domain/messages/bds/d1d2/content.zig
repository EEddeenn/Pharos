const field = @import("base/binary/field");
const ephemeris = @import("domain/messages/bds/d1d2/ephemeris");
const fields = @import("domain/messages/bds/d1d2/fields");
const carriage = @import("domain/messages/carriage");
const time = @import("domain/time/gps");
const Kepler = @import("domain/navigation/reference").Kepler;
const Parameters = @import("domain/navigation/orbit/parameters").Parameters;
const GpsTime = time.GpsTime;
pub const Prepared = struct {
    codes: fields.Codes,
    decoded: Parameters,
    prediction: ?GpsTime,

    pub fn at(self: *const Prepared, t: GpsTime) fields.Codes {
        var out = self.codes;
        out.wn = @intCast(@mod(t.inScale(.bds).period, time.week_modulus_13));
        if (self.prediction) |p| {
            out.aodc = ephemeris.ageCode(p, t);
            out.aode = out.aodc;
        }
        return out;
    }
};

pub const Content = carriage.Carriage(Prepared);
pub const Orbit = union(enum) { original, fitted: Parameters };
pub const Choice = union(enum) { original, fitted: Parameters, unfit: carriage.Unfit };
pub const Preparation = struct { choice: Choice, content: Content };

pub const toe_step_ms = ephemeris.toe_step_ms;

pub fn prepare(record: Kepler, orbit: ?Orbit) Preparation {
    const selected = orbit orelse return .{ .choice = .{ .unfit = .fit }, .content = .{ .unfit = .fit } };
    const parameters = switch (selected) {
        .original => record.record.parameters(),
        .fitted => |p| p,
    };
    const metadata = ephemeris.metadata(record, &parameters);
    const sv: ephemeris.Sv = .{ .eph = parameters, .metadata = metadata, .klobuchar = .of(.zero) };
    const codes = switch (field.prepare(ephemeris.Sv, &fields.navigation_rows, &sv)) {
        .codes => |c| c,
        .badfield => |name| {
            const why: carriage.Unfit = .{ .field = name };
            return .{ .choice = .{ .unfit = why }, .content = .{ .unfit = why } };
        },
    };
    const choice: Choice = switch (selected) {
        .original => .original,
        .fitted => |p| .{ .fitted = p },
    };
    return .{ .choice = choice, .content = .{ .carried = .{ .codes = codes, .decoded = fields.decoded(codes, &parameters), .prediction = metadata.prediction } } };
}

pub fn project(record: Kepler, choice: Choice) Content {
    const parameters = switch (choice) {
        .original => record.record.parameters(),
        .fitted => |p| p,
        .unfit => |why| return .{ .unfit = why },
    };
    const metadata = ephemeris.metadata(record, &parameters);
    const sv: ephemeris.Sv = .{ .eph = parameters, .metadata = metadata, .klobuchar = .of(.zero) };
    const codes = field.project(ephemeris.Sv, &fields.navigation_rows, &sv);
    return .{ .carried = .{ .codes = codes, .decoded = fields.decoded(codes, &parameters), .prediction = metadata.prediction } };
}

pub fn carried(e: *const Parameters) bool {
    return e.a_dot == 0 and e.delta_n_dot == 0 and fields.floorTo8s(e.toe).eql(e.toe) and fields.floorTo8s(e.toc).eql(e.toc);
}
