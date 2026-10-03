const std = @import("std");
const core = @import("../../core.zig");
const field = @import("../../codec.zig").field;
const records = @import("../records.zig");
const constants = @import("constants.zig");
const cnvx = @import("cnvx.zig");
pub const fit = @import("dc/fit.zig");

const GpsTime = core.time.GpsTime;
const Eph = records.KeplerEphemeris;

pub const data_type_lnav: u1 = 1;
pub const no_data_prn: u8 = 0xFF;
pub const epoch_ms: i64 = 300_000;

pub const Correction = struct {
    prn: u8,
    af0: f64 = 0,
    af1: f64 = 0,
    alpha: f64 = 0,
    beta: f64 = 0,
    gamma: f64 = 0,
    delta_i: f64 = 0,
    delta_omega: f64 = 0,
    delta_a: f64 = 0,
};

pub const Packet = struct { corr: Correction, udra: i5, udra_rate: i5 };

const P = field.Field(Packet);
pub const cdc = [_]P{
    .{ .name = "prn_cdc", .width = 8, .renamed = true, .src = .{ .field = "corr.prn" } },
    .{ .name = "af0", .width = 13, .repr = .twos, .scale_log2 = -35, .src = .{ .field = "corr.af0" } },
    .{ .name = "af1", .width = 8, .repr = .twos, .scale_log2 = -51, .src = .{ .field = "corr.af1" } },
    .{ .name = "udra", .width = 5, .repr = .twos, .src = .{ .field = "udra" } },
};
pub const edc = [_]P{
    .{ .name = "prn_edc", .width = 8, .renamed = true, .src = .{ .field = "corr.prn" } },
    .{ .name = "alpha", .width = 14, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "corr.alpha" } },
    .{ .name = "beta", .width = 14, .repr = .twos, .scale_log2 = -34, .src = .{ .field = "corr.beta" } },
    .{ .name = "gamma", .width = 15, .repr = .twos, .scale_log2 = -32, .semicircles = true, .src = .{ .field = "corr.gamma" } },
    .{ .name = "delta_i", .width = 12, .repr = .twos, .scale_log2 = -32, .semicircles = true, .src = .{ .field = "corr.delta_i" } },
    .{ .name = "delta_omega", .width = 12, .repr = .twos, .scale_log2 = -32, .semicircles = true, .src = .{ .field = "corr.delta_omega" } },
    .{ .name = "delta_a", .width = 12, .repr = .twos, .scale_log2 = -9, .src = .{ .field = "corr.delta_a" } },
    .{ .name = "udra_rate", .width = 5, .repr = .twos, .src = .{ .field = "udra_rate" } },
};

pub fn representable(c: Correction) bool {
    const p: Packet = .{ .corr = c, .udra = 0, .udra_rate = 0 };
    return field.fits(Packet, &cdc, &p) and field.fits(Packet, &edc, &p);
}

pub const Epoch = struct {
    t_od: GpsTime,

    fn count(e: *const Epoch) i64 {
        return @divFloor(@as(i64, e.t_od.msOfWeek()), epoch_ms);
    }
};
pub const epoch = [_]field.Field(Epoch){
    .{ .name = "top_d", .width = 11, .src = .{ .computed_int = &Epoch.count } },
    .{ .name = "t_od", .width = 11, .src = .{ .computed_int = &Epoch.count } },
};

pub fn epochOf(t: GpsTime) GpsTime {
    return .{ .ms = @divFloor(t.ms, epoch_ms) * epoch_ms };
}

pub const Batch = struct {
    t_od: GpsTime,
    corrections: [32]?Correction = @splat(null),

    pub fn targets(self: *const Batch, prn: u8) cnvx.Prns {
        var out: cnvx.Prns = .{};
        for (self.corrections, 1..) |entry, number| {
            if (entry == null or number == prn) continue;
            out.list[out.len] = @intCast(number);
            out.len += 1;
        }
        return out;
    }
};

pub const Source = struct {
    ptr: *const anyopaque,
    batchFn: *const fn (*const anyopaque, GpsTime, GpsTime) ?Batch,

    pub fn batch(self: Source, t_od: GpsTime, t: GpsTime) ?Batch {
        return self.batchFn(self.ptr, t_od, t);
    }

    pub fn of(comptime T: type, supplier: *const T) Source {
        return .{ .ptr = supplier, .batchFn = struct {
            fn call(p: *const anyopaque, t_od: GpsTime, t: GpsTime) ?Batch {
                const s: *const T = @ptrCast(@alignCast(p));
                return s.batch(t_od, t);
            }
        }.call };
    }
};

pub fn applied(record: *const Eph, c: Correction, t_od: GpsTime) @import("../kepler_parameters.zig").Parameters {
    const a = record.sqrt_a * record.sqrt_a;
    const alpha = record.ecc * @cos(record.w) + c.alpha;
    const beta = record.ecc * @sin(record.w) + c.beta;
    const gamma = record.m0 + record.w + c.gamma;
    const w = std.math.atan2(beta, alpha);
    const dm0 = -1.5 * @sqrt(constants.orbit.mu / (a * a * a)) * (c.delta_a / a) * record.toe.secondsSince(t_od);
    var out = record.parameters();
    out.sqrt_a = @sqrt(a + c.delta_a);
    out.ecc = @sqrt(alpha * alpha + beta * beta);
    out.i0 = record.i0 + c.delta_i;
    out.omega0 = record.omega0 + c.delta_omega;
    out.w = w;
    out.m0 = gamma - w + dm0;
    out.af0 = record.af0 + c.af0;
    out.af1 = record.af1 + c.af1;
    return out;
}

comptime {
    std.debug.assert(field.totalWidth(Packet, &cdc) == 34);
    std.debug.assert(field.totalWidth(Packet, &edc) == 92);
    std.debug.assert(field.totalWidth(Epoch, &epoch) == 22);
}
