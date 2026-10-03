const std = @import("std");
const core = @import("../core.zig");
const gnss = @import("../gnss.zig");
const provider = @import("../track.zig").provider;
const receiver = @import("receiver.zig");
const coord = core.coord;
const GpsTime = core.time.GpsTime;
const lighttime = core.lighttime;
const hermite = @import("../trajectory/hermite.zig");

pub const Knot = struct {
    t: GpsTime,
    state: provider.State,
    lt: lighttime.Result,
    el_rad: f64,
    az_rad: f64,
};

pub const Look = struct { lt: lighttime.Result, el_rad: f64, az_rad: f64 };

pub fn look(source: anytype, rx: receiver.Frame, t: GpsTime, omega_e: f64, first: lighttime.Sample) Look {
    const lt = lighttime.solve(source, rx.pos, t, omega_e, first);
    const elaz = rx.enu.elAz(lt.los);
    return .{ .lt = lt, .el_rad = elaz.el_rad, .az_rad = elaz.az_rad };
}

pub fn knot(source: *provider.Track, rx: receiver.Frame, t: GpsTime, omega_e: f64) Knot {
    const state = source.stateAt(t);
    const seen = look(source, rx, t, omega_e, .{ .pos = state.pos, .vel = state.vel });
    return .{ .t = t, .state = state, .lt = seen.lt, .el_rad = seen.el_rad, .az_rad = seen.az_rad };
}

pub const Entry = struct {
    sat: core.types.SatId,
    knots: ?*const [2]Knot = null,

    pub fn ready(self: *const Entry) ?Ready {
        return if (self.knots) |knots| .{ .sat = self.sat, .knots = knots } else null;
    }
};

pub const Frame = struct { tracks: []const Entry };

pub const Ready = struct {
    sat: core.types.SatId,
    knots: *const [2]Knot,

    pub fn stateAt(self: Ready, t: GpsTime) lighttime.Sample {
        return Interpolation(f64, GpsTime).stateAt(&self.knots[0], &self.knots[1], t);
    }

    pub fn clockBiasAt(self: Ready, t: GpsTime) f64 {
        return Interpolation(f64, GpsTime).clockBiasAt(&self.knots[0], &self.knots[1], t);
    }

    pub fn relAt(self: Ready, t: GpsTime) f64 {
        return Interpolation(f64, GpsTime).relAt(&self.knots[0], &self.knots[1], t);
    }

    pub fn columnsAt(self: Ready, t: GpsTime) coord.ElAz {
        return Interpolation(f64, GpsTime).columnsAt(&self.knots[0], &self.knots[1], t);
    }

    pub fn omegaEarth(self: Ready) f64 {
        return gnss.constants.get(self.sat.system).omega_e;
    }
};

pub fn Interpolation(comptime Number: type, comptime Time: type) type {
    return struct {
        const Hermite = hermite.Interpolation(Number, hermite.Float(Number));
        const Sample = lighttime.Solver(Number, Time).Sample;
        const Angles = if (Number == f64) coord.ElAz else struct { el_rad: Number, az_rad: Number };

        fn basis(k0: anytype, k1: anytype, t: Time) Hermite.CubicBasis {
            const h = k1.t.secondsSince(k0.t);
            const s = t.secondsSince(k0.t) / h;
            return Hermite.cubicBasis(h, s);
        }

        pub fn fraction(k0: anytype, k1: anytype, t: Time) Number {
            return t.secondsSince(k0.t) / k1.t.secondsSince(k0.t);
        }

        pub fn stateAt(k0: anytype, k1: anytype, t: Time) Sample {
            const b = basis(k0, k1, t);
            const h = b.h;
            const d = b.velocity();
            return .{
                .pos = k0.state.pos.scale(b.h00).add(k0.state.vel.scale(b.h10 * h)).add(k1.state.pos.scale(b.h01)).add(k1.state.vel.scale(b.h11 * h)),
                .vel = k0.state.pos.scale(d[0]).add(k0.state.vel.scale(d[1])).add(k1.state.pos.scale(d[2])).add(k1.state.vel.scale(d[3])),
            };
        }

        pub fn clockBiasAt(k0: anytype, k1: anytype, t: Time) Number {
            const b = basis(k0, k1, t);
            return b.h00 * k0.state.clock_bias_s + b.h10 * b.h * k0.state.clock_drift + b.h01 * k1.state.clock_bias_s + b.h11 * b.h * k1.state.clock_drift;
        }

        pub fn relAt(k0: anytype, k1: anytype, t: Time) Number {
            const f = fraction(k0, k1, t);
            return k0.state.rel_s + (k1.state.rel_s - k0.state.rel_s) * f;
        }

        pub fn columnsAt(k0: anytype, k1: anytype, t: Time) Angles {
            const f = fraction(k0, k1, t);
            const az = if (Number == f64) azimuthAt(k0.az_rad, k1.az_rad, f) else blk: {
                var values: Number = undefined;
                inline for (0..@typeInfo(Number).vector.len) |i| values[i] = azimuthAt(k0.az_rad[i], k1.az_rad[i], f[i]);
                break :blk values;
            };
            return .{
                .el_rad = k0.el_rad + (k1.el_rad - k0.el_rad) * f,
                .az_rad = az,
            };
        }
    };
}

fn azimuthAt(a0: f64, a1: f64, f: f64) f64 {
    var d = a1 - a0;
    if (d > std.math.pi) d -= std.math.tau else if (d < -std.math.pi) d += std.math.tau;
    return @mod(a0 + d * f, std.math.tau);
}
